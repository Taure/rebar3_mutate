-module(rebar3_mutate_prv).

-behaviour(provider).

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, mutate).
-define(DEPS, [{default, app_discovery}, {default, compile}]).
-define(DEFAULT_TIMEOUT, 5000).
-define(DEFAULT_WORKERS, erlang:system_info(schedulers)).
-define(BASELINE_TIMEOUT_FLOOR, 30000).

init(State) ->
    Provider = providers:create([
        {name, ?PROVIDER},
        {module, ?MODULE},
        {bare, true},
        {deps, ?DEPS},
        {profiles, [test]},
        {example, "rebar3 mutate --module my_module"},
        {opts, [
            {module, $m, "module", string, "Target module(s), comma-separated"},
            {exclude, $x, "exclude", string, "Modules to exclude, comma-separated"},
            {timeout, $t, "timeout", integer,
                "Per-mutant timeout in ms (default: " ++
                    integer_to_list(?DEFAULT_TIMEOUT) ++ ")"},
            {operators, $o, "operators", string,
                "Operators to use, comma-separated (default: all). "
                "Available: op_arithmetic, op_relational, op_boolean, op_return_value, "
                "op_statement_delete, op_constant, op_negate_condition, op_list"},
            {test_framework, $f, "test-framework", string, "Test framework: eunit (default) or ct"},
            {suite, undefined, "suite", string,
                "Common Test suite to run (default: <module>_SUITE)"},
            {min_score, $s, "min-score", string, "Minimum mutation score (0-100). Fail if below"},
            {format, undefined, "format", string, "Output format: console (default) or json"},
            {workers, $w, "workers", integer,
                "Number of parallel workers (default: scheduler count)"},
            {diff, $d, "diff", string,
                "Only mutate lines changed since base ref (e.g. origin/main)"}
        ]},
        {short_desc, "Run mutation testing on project modules"},
        {desc,
            "Generates mutants by applying small code changes and checks whether "
            "your tests detect them. Reports a mutation score and lists surviving mutants."}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.

do(State) ->
    try
        run(State, options(State))
    catch
        throw:{mutate_error, Message} ->
            {error, {?MODULE, Message}}
    end.

format_error(Reason) when is_list(Reason) ->
    Reason;
format_error(Reason) ->
    io_lib:format("~p", [Reason]).

%%====================================================================
%% Run
%%====================================================================

options(State) ->
    {Args, _} = rebar_state:command_parsed_args(State),
    #{
        timeout => proplists:get_value(timeout, Args, ?DEFAULT_TIMEOUT),
        operators => parse_operators(proplists:get_value(operators, Args, undefined)),
        modules => parse_modules(proplists:get_value(module, Args, undefined)),
        exclude => parse_modules(proplists:get_value(exclude, Args, undefined)),
        framework => parse_test_framework(proplists:get_value(test_framework, Args, undefined)),
        suite => proplists:get_value(suite, Args, undefined),
        min_score => parse_min_score(proplists:get_value(min_score, Args, undefined)),
        format => parse_format(proplists:get_value(format, Args, undefined)),
        workers => proplists:get_value(workers, Args, ?DEFAULT_WORKERS),
        diff => parse_diff(proplists:get_value(diff, Args, undefined))
    }.

run(State, Opts) ->
    Targets = collect_targets(rebar_state:project_apps(State), Opts),
    ok = check_targets(Targets, Opts),
    Outcomes = [process_file(File, IncludeDirs, Opts) || {File, IncludeDirs} <- Targets],
    Scored = [{Module, Results} || {ok, Module, Results} <- Outcomes],
    Skipped = [{Module, Reason} || {skipped, Module, Reason} <- Outcomes],
    Failed = [{Module, Reason} || {baseline_failed, Module, Reason} <- Outcomes],
    report(Scored, Skipped, Failed, Opts),
    gate(State, Scored, Failed, Opts).

collect_targets(Apps, #{modules := Modules, exclude := Exclude, diff := DiffFilter}) ->
    lists:append([
        begin
            AppDir = rebar_app_info:dir(AppInfo),
            SrcDir = filename:join(AppDir, "src"),
            IncludeDirs = [filename:join(AppDir, "include"), AppDir],
            Files = find_source_files(SrcDir, Modules, Exclude),
            [{File, IncludeDirs} || File <- filter_files_by_diff(Files, DiffFilter)]
        end
     || AppInfo <- Apps
    ]).

%% An explicit -m that matches nothing used to run zero mutants, which the
%% --min-score gate then treated as a pass.
check_targets([], #{modules := Modules}) when Modules =/= all ->
    throw(
        {mutate_error,
            io_lib:format(
                "No source files matched --module ~s",
                [lists:join(",", [atom_to_list(M) || M <- Modules])]
            )}
    );
check_targets(_Targets, _Opts) ->
    ok.

process_file(File, IncludeDirs, Opts) ->
    case rebar3_mutate_ast:parse_file(File, IncludeDirs) of
        {ok, Module, Forms} ->
            process_module(Module, Forms, File, Opts);
        {error, Reason} ->
            rebar_api:warn("Skipping ~s: ~p", [File, Reason]),
            {skipped, list_to_atom(filename:basename(File, ".erl")), {parse_failed, Reason}}
    end.

process_module(Module, Forms, File, Opts) ->
    case resolve_test_spec(Module, Opts) of
        {error, Reason} ->
            rebar_api:warn("~s: skipped (~p)", [Module, Reason]),
            {skipped, Module, Reason};
        {ok, TestSpec} ->
            baseline_then_mutate(Module, Forms, File, TestSpec, Opts)
    end.

baseline_then_mutate(Module, Forms, File, TestSpec, #{timeout := Timeout} = Opts) ->
    BaselineTimeout = max(Timeout * 4, ?BASELINE_TIMEOUT_FLOOR),
    case rebar3_mutate_runner:run_baseline(Module, TestSpec, BaselineTimeout) of
        no_tests ->
            rebar_api:warn("~s: no tests found, skipped", [Module]),
            {skipped, Module, no_tests};
        {failed, Reason} ->
            rebar_api:error("~s: tests do not pass unmutated (~p)", [Module, Reason]),
            {baseline_failed, Module, Reason};
        {ok, BaselineMs} ->
            mutate_module(Module, Forms, File, TestSpec, BaselineMs, Opts)
    end.

mutate_module(Module, Forms, File, TestSpec, BaselineMs, Opts) ->
    #{operators := Operators, workers := Workers, diff := DiffFilter} = Opts,
    AllPoints = rebar3_mutate_ast:mutation_points(Forms, Operators),
    Points = filter_by_diff(AllPoints, File, DiffFilter),
    log_points(Module, length(AllPoints), length(Points)),
    Timeout = mutant_timeout(Module, maps:get(timeout, Opts), BaselineMs),
    Results = run_points(Points, Forms, Module, TestSpec, Timeout, Workers),
    {ok, Module, Results}.

%% A per-mutant timeout below the suite's own runtime turns every mutant into a
%% timeout, so the whole run reports nothing usable.
mutant_timeout(Module, Timeout, BaselineMs) when BaselineMs >= Timeout ->
    Raised = BaselineMs * 5,
    rebar_api:warn(
        "~s: unmutated suite takes ~Bms, raising per-mutant timeout ~Bms -> ~Bms",
        [Module, BaselineMs, Timeout, Raised]
    ),
    Raised;
mutant_timeout(_Module, Timeout, _BaselineMs) ->
    Timeout.

log_points(Module, Total, Total) ->
    rebar_api:info("~s: ~B mutation points found", [Module, Total]);
log_points(Module, Total, Filtered) ->
    rebar_api:info("~s: ~B/~B mutation points in diff", [Module, Filtered, Total]).

%% Mutants are compiled in parallel because that is pure computation, then
%% loaded and tested one at a time because the code server only holds two
%% versions of a module.
run_points(Points, Forms, Module, TestSpec, Timeout, Workers) ->
    Compiled = rebar3_mutate_pool:pmap(
        fun(Point) ->
            MutatedForms = rebar3_mutate_ast:apply_mutation(Forms, Point),
            rebar3_mutate_runner:compile_mutant(Module, MutatedForms)
        end,
        Points,
        Workers
    ),
    lists:map(
        fun
            ({Point, {ok, Binary}}) ->
                progress(
                    Point, rebar3_mutate_runner:load_and_test(Module, Binary, TestSpec, Timeout)
                );
            ({Point, Other}) ->
                progress(Point, Other)
        end,
        lists:zip(Points, Compiled)
    ).

progress(Point, Result) ->
    io:put_chars(standard_error, marker(Result)),
    {Point, Result}.

marker(killed) -> ".";
marker(survived) -> "S";
marker(timed_out) -> "T";
marker({compile_error, _}) -> "E";
marker({skipped, _}) -> "-".

%%====================================================================
%% Reporting and gating
%%====================================================================

report(Scored, Skipped, Failed, #{format := console}) ->
    lists:foreach(
        fun({Module, Results}) -> rebar3_mutate_report:format(Module, Results) end, Scored
    ),
    Counts = rebar3_mutate_report:total_count(Scored),
    lists:foreach(
        fun({Module, Reason}) -> rebar_api:warn("Skipped ~s: ~p", [Module, Reason]) end,
        Skipped
    ),
    lists:foreach(
        fun({Module, Reason}) -> rebar_api:error("Baseline failed ~s: ~p", [Module, Reason]) end,
        Failed
    ),
    rebar_api:info("~nOverall: ~B/~B mutants killed (~.1f%)", [
        maps:get(killed, Counts),
        rebar3_mutate_report:testable(Counts),
        rebar3_mutate_report:score(Counts)
    ]);
report(Scored, Skipped, Failed, #{format := json}) ->
    Json = rebar3_mutate_report:format_json(Scored, Skipped ++ Failed),
    io:nl(),
    io:put_chars(Json),
    io:nl().

gate(_State, _Scored, [{Module, Reason} | _], _Opts) ->
    {error,
        {?MODULE,
            io_lib:format(
                "~s: tests do not pass unmutated (~p); mutation results are meaningless",
                [Module, Reason]
            )}};
gate(State, _Scored, [], #{min_score := undefined}) ->
    {ok, State};
gate(State, Scored, [], #{min_score := Threshold}) ->
    Counts = rebar3_mutate_report:total_count(Scored),
    case rebar3_mutate_report:testable(Counts) of
        0 ->
            {ok, State};
        _ ->
            Score = rebar3_mutate_report:score(Counts),
            case Score >= Threshold of
                true ->
                    {ok, State};
                false ->
                    {error,
                        {?MODULE,
                            io_lib:format(
                                "Mutation score ~.1f% is below minimum ~.1f%",
                                [Score, Threshold]
                            )}}
            end
    end.

%%====================================================================
%% Options
%%====================================================================

parse_modules(undefined) -> all;
parse_modules(Str) -> [list_to_atom(string:trim(S)) || S <- string:split(Str, ",", all)].

parse_operators(undefined) ->
    rebar3_mutate_operators:all();
parse_operators(Str) ->
    Known = rebar3_mutate_operators:all(),
    Requested = [list_to_atom(string:trim(S)) || S <- string:split(Str, ",", all)],
    case Requested -- Known of
        [] ->
            Requested;
        Unknown ->
            throw(
                {mutate_error,
                    io_lib:format("Unknown operator(s): ~s", [
                        lists:join(",", [atom_to_list(O) || O <- Unknown])
                    ])}
            )
    end.

parse_test_framework(undefined) ->
    eunit;
parse_test_framework("eunit") ->
    eunit;
parse_test_framework("ct") ->
    ct;
parse_test_framework(Other) ->
    throw(
        {mutate_error, io_lib:format("Unknown test framework '~s'; expected eunit or ct", [Other])}
    ).

parse_format(undefined) ->
    console;
parse_format("console") ->
    console;
parse_format("json") ->
    json;
parse_format(Other) ->
    throw({mutate_error, io_lib:format("Unknown format '~s'; expected console or json", [Other])}).

parse_min_score(undefined) ->
    undefined;
parse_min_score(Str) ->
    try
        list_to_float(Str)
    catch
        error:badarg ->
            try
                float(list_to_integer(Str))
            catch
                error:badarg ->
                    throw(
                        {mutate_error,
                            io_lib:format("Invalid --min-score '~s'; expected a number", [Str])}
                    )
            end
    end.

parse_diff(undefined) ->
    none;
parse_diff(BaseRef) ->
    rebar_api:info("Diff mode: only mutating lines changed since ~s", [BaseRef]),
    case rebar3_mutate_diff:changed_lines(BaseRef) of
        {ok, Changes} ->
            {diff, Changes};
        {error, Reason} ->
            throw({mutate_error, io_lib:format("Cannot diff against '~s': ~p", [BaseRef, Reason])})
    end.

resolve_test_spec(_Module, #{framework := eunit}) ->
    {ok, eunit};
resolve_test_spec(_Module, #{framework := ct, suite := Suite}) when Suite =/= undefined ->
    {ok, {ct, list_to_atom(Suite)}};
resolve_test_spec(Module, #{framework := ct}) ->
    Suite = list_to_atom(atom_to_list(Module) ++ "_SUITE"),
    case code:ensure_loaded(Suite) of
        {module, Suite} -> {ok, {ct, Suite}};
        {error, _} -> {error, {no_ct_suite, Suite}}
    end.

%%====================================================================
%% File selection
%%====================================================================

find_source_files(SrcDir, Modules, ExcludeModules) ->
    Files = filelib:wildcard(filename:join([SrcDir, "**", "*.erl"])),
    Selected =
        case Modules of
            all -> Files;
            _ -> [F || F <- Files, lists:member(module_of(F), Modules)]
        end,
    case ExcludeModules of
        all -> Selected;
        _ -> [F || F <- Selected, not lists:member(module_of(F), ExcludeModules)]
    end.

module_of(File) ->
    list_to_atom(filename:basename(File, ".erl")).

filter_files_by_diff(Files, none) ->
    Files;
filter_files_by_diff(Files, {diff, Changes}) ->
    [F || F <- Files, find_matching_file(F, Changes) =/= none].

filter_by_diff(Points, _File, none) ->
    Points;
filter_by_diff(Points, File, {diff, Changes}) ->
    case find_matching_file(File, Changes) of
        {ok, Ranges} ->
            [P || P <- Points, in_ranges(rebar3_mutate_ast:get_point_line(P), Ranges)];
        none ->
            []
    end.

find_matching_file(File, Changes) ->
    maps:fold(
        fun
            (DiffPath, Ranges, none) ->
                case rebar3_mutate_diff:matches_path(File, DiffPath) of
                    true -> {ok, Ranges};
                    false -> none
                end;
            (_DiffPath, _Ranges, Found) ->
                Found
        end,
        none,
        Changes
    ).

in_ranges(_Line, []) -> false;
in_ranges(Line, [{Start, End} | _]) when Line >= Start, Line =< End -> true;
in_ranges(Line, [_ | Rest]) -> in_ranges(Line, Rest).
