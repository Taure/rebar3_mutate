-module(rebar3_mutate_prv).

-behaviour(provider).

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, mutate).
-define(DEPS, [{default, app_discovery}, {default, compile}]).
-define(DEFAULT_TIMEOUT, 5000).
-define(DEFAULT_WORKERS, erlang:system_info(schedulers)).

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
            {min_score, $s, "min-score", float, "Minimum mutation score (0-100). Fail if below"},
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
    {Args, _} = rebar_state:command_parsed_args(State),
    Timeout = proplists:get_value(timeout, Args, ?DEFAULT_TIMEOUT),
    Operators = parse_operators(proplists:get_value(operators, Args, undefined)),
    TargetModules = parse_modules(proplists:get_value(module, Args, undefined)),
    ExcludeModules = parse_modules(proplists:get_value(exclude, Args, undefined)),
    TestSpec = parse_test_framework(proplists:get_value(test_framework, Args, undefined)),
    MinScore = proplists:get_value(min_score, Args, undefined),
    Format = parse_format(proplists:get_value(format, Args, undefined)),
    Workers = proplists:get_value(workers, Args, ?DEFAULT_WORKERS),
    DiffFilter = parse_diff(proplists:get_value(diff, Args, undefined)),

    Apps = rebar_state:project_apps(State),
    AllResults = lists:foldl(
        fun(AppInfo, Acc) ->
            AppDir = rebar_app_info:dir(AppInfo),
            SrcDir = filename:join(AppDir, "src"),
            IncludeDir = filename:join(AppDir, "include"),
            SrcFiles0 = find_source_files(SrcDir, TargetModules, ExcludeModules),
            SrcFiles = filter_files_by_diff(SrcFiles0, DiffFilter),
            lists:foldl(
                fun(File, InnerAcc) ->
                    case
                        process_file(
                            File,
                            [IncludeDir, AppDir],
                            Operators,
                            TestSpec,
                            Timeout,
                            Workers,
                            DiffFilter
                        )
                    of
                        {ok, Module, Results} ->
                            [{Module, Results} | InnerAcc];
                        {error, Reason} ->
                            rebar_api:warn("Skipping ~s: ~p", [File, Reason]),
                            InnerAcc
                    end
                end,
                Acc,
                SrcFiles
            )
        end,
        [],
        Apps
    ),

    TotalKilled = lists:sum([length([R || {_, R} <- Rs, R =:= killed]) || {_, Rs} <- AllResults]),
    TotalMutants = lists:sum([length(Rs) || {_, Rs} <- AllResults]),
    TotalCompileErrors = lists:sum([
        length([R || {_, R} <- Rs, is_compile_error(R)])
     || {_, Rs} <- AllResults
    ]),

    case Format of
        console ->
            lists:foreach(
                fun({Module, Results}) ->
                    rebar3_mutate_report:format(Module, Results)
                end,
                lists:reverse(AllResults)
            ),
            rebar_api:info("~nOverall: ~B/~B mutants killed", [TotalKilled, TotalMutants]);
        json ->
            Json = rebar3_mutate_report:format_json(lists:reverse(AllResults)),
            io:put_chars(Json),
            io:nl()
    end,

    OverallScore = score(TotalKilled, TotalMutants, TotalCompileErrors),
    case MinScore of
        undefined ->
            {ok, State};
        Threshold when OverallScore >= Threshold ->
            {ok, State};
        Threshold ->
            {error,
                {?MODULE,
                    io_lib:format(
                        "Mutation score ~.1f% is below minimum ~.1f%",
                        [OverallScore, Threshold]
                    )}}
    end.

format_error(Reason) ->
    io_lib:format("~p", [Reason]).

%%====================================================================
%% Internal
%%====================================================================

process_file(File, IncludeDirs, Operators, TestSpec, Timeout, Workers, DiffFilter) ->
    case rebar3_mutate_ast:parse_file(File, IncludeDirs) of
        {ok, Module, Forms} ->
            AllPoints = rebar3_mutate_ast:mutation_points(Forms, Operators),
            Points = filter_by_diff(AllPoints, File, DiffFilter),
            case {length(AllPoints), length(Points)} of
                {Total, Total} ->
                    rebar_api:info("~s: ~B mutation points found", [Module, Total]);
                {Total, Filtered} ->
                    rebar_api:info("~s: ~B/~B mutation points in diff", [Module, Filtered, Total])
            end,
            Results = run_parallel(Points, Forms, Module, Operators, TestSpec, Timeout, Workers),
            {ok, Module, Results};
        {error, _} = Err ->
            Err
    end.

run_parallel(Points, Forms, Module, Operators, TestSpec, Timeout, Workers) when Workers > 1 ->
    %% Phase 1: compile all mutants in parallel (safe — pure computation)
    CompileTasks = lists:map(
        fun(Point) ->
            {Point, Forms, Operators}
        end,
        Points
    ),
    Compiled = pmap(
        fun({Point, Fs, Ops}) ->
            MutatedForms = rebar3_mutate_ast:apply_mutation(Fs, Point, Ops),
            {Point, rebar3_mutate_runner:compile_mutant(Module, MutatedForms)}
        end,
        CompileTasks,
        Workers
    ),
    %% Phase 2: load and test sequentially (BEAM only supports 2 module versions)
    lists:map(
        fun
            ({Point, {ok, Binary}}) ->
                Result = rebar3_mutate_runner:load_and_test(Module, Binary, TestSpec, Timeout),
                print_progress(Result),
                {Point, Result};
            ({Point, {compile_error, _} = Err}) ->
                print_progress(Err),
                {Point, Err}
        end,
        Compiled
    );
run_parallel(Points, Forms, Module, Operators, TestSpec, Timeout, _Workers) ->
    lists:map(
        fun(Point) ->
            MutatedForms = rebar3_mutate_ast:apply_mutation(Forms, Point, Operators),
            Result = rebar3_mutate_runner:run_mutant(Module, MutatedForms, TestSpec, Timeout),
            print_progress(Result),
            {Point, Result}
        end,
        Points
    ).

pmap(Fun, Tasks, MaxWorkers) ->
    Parent = self(),
    Ref = make_ref(),
    IndexedTasks = lists:zip(lists:seq(1, length(Tasks)), Tasks),
    %% Chunk into groups of MaxWorkers
    Chunks = chunk(IndexedTasks, MaxWorkers),
    Results = lists:flatmap(
        fun(Chunk) ->
            Pids = lists:map(
                fun({Idx, Task}) ->
                    spawn_monitor(fun() ->
                        Parent ! {Ref, Idx, Fun(Task)}
                    end)
                end,
                Chunk
            ),
            collect(Ref, Pids, [])
        end,
        Chunks
    ),
    [R || {_, R} <- lists:keysort(1, Results)].

collect(_Ref, [], Acc) ->
    Acc;
collect(Ref, Pids, Acc) ->
    receive
        {Ref, Idx, Result} ->
            collect(Ref, Pids, [{Idx, Result} | Acc]);
        {'DOWN', MRef, process, _Pid, normal} ->
            collect(Ref, lists:keydelete(MRef, 2, Pids), Acc);
        {'DOWN', MRef, process, _Pid, Reason} ->
            rebar_api:warn("Worker crashed: ~p", [Reason]),
            collect(Ref, lists:keydelete(MRef, 2, Pids), Acc)
    end.

chunk([], _N) ->
    [];
chunk(List, N) ->
    {Head, Tail} = safe_split(N, List),
    [Head | chunk(Tail, N)].

safe_split(N, List) when length(List) =< N ->
    {List, []};
safe_split(N, List) ->
    lists:split(N, List).

print_progress(killed) -> io:put_chars(standard_error, ".");
print_progress(survived) -> io:put_chars(standard_error, "S");
print_progress(timed_out) -> io:put_chars(standard_error, "T");
print_progress({compile_error, _}) -> io:put_chars(standard_error, "E").

find_source_files(SrcDir, all, ExcludeModules) ->
    Files = filelib:wildcard(filename:join([SrcDir, "**", "*.erl"])),
    exclude_files(Files, ExcludeModules);
find_source_files(SrcDir, Modules, ExcludeModules) ->
    AllFiles = filelib:wildcard(filename:join([SrcDir, "**", "*.erl"])),
    Filtered = lists:filter(
        fun(File) ->
            Mod = list_to_atom(filename:basename(File, ".erl")),
            lists:member(Mod, Modules)
        end,
        AllFiles
    ),
    exclude_files(Filtered, ExcludeModules).

exclude_files(Files, all) ->
    Files;
exclude_files(Files, ExcludeModules) ->
    lists:filter(
        fun(File) ->
            Mod = list_to_atom(filename:basename(File, ".erl")),
            not lists:member(Mod, ExcludeModules)
        end,
        Files
    ).

parse_modules(undefined) -> all;
parse_modules(Str) -> [list_to_atom(string:trim(S)) || S <- string:split(Str, ",", all)].

parse_operators(undefined) ->
    rebar3_mutate_operators:all();
parse_operators(Str) ->
    [list_to_atom(string:trim(S)) || S <- string:split(Str, ",", all)].

parse_test_framework(undefined) ->
    eunit;
parse_test_framework("eunit") ->
    eunit;
parse_test_framework("ct") ->
    ct;
parse_test_framework(Other) ->
    rebar_api:warn("Unknown test framework '~s', defaulting to eunit", [Other]),
    eunit.

parse_diff(undefined) ->
    none;
parse_diff(BaseRef) ->
    rebar_api:info("Diff mode: only mutating lines changed since ~s", [BaseRef]),
    case rebar3_mutate_diff:changed_lines(BaseRef) of
        {ok, Changes} ->
            {diff, Changes};
        {error, Reason} ->
            rebar_api:error("Failed to parse git diff: ~p", [Reason]),
            erlang:error({diff_failed, Reason})
    end.

filter_by_diff(Points, _File, none) ->
    Points;
filter_by_diff(Points, File, {diff, Changes}) ->
    %% Match file path suffix — git diff gives repo-relative paths,
    %% while File is an absolute path
    case find_matching_file(File, Changes) of
        {ok, Ranges} ->
            [P || P <- Points, in_ranges(rebar3_mutate_ast:get_point_line(P), Ranges)];
        none ->
            []
    end.

filter_files_by_diff(Files, none) ->
    Files;
filter_files_by_diff(Files, {diff, Changes}) ->
    [F || F <- Files, find_matching_file(F, Changes) =/= none].

find_matching_file(_File, Changes) when map_size(Changes) =:= 0 ->
    none;
find_matching_file(File, Changes) ->
    maps:fold(
        fun(DiffPath, Ranges, Acc) ->
            case Acc of
                {ok, _} ->
                    Acc;
                none ->
                    case string:find(File, DiffPath, trailing) of
                        nomatch -> none;
                        _ -> {ok, Ranges}
                    end
            end
        end,
        none,
        Changes
    ).

in_ranges(_Line, []) -> false;
in_ranges(Line, [{Start, End} | _]) when Line >= Start, Line =< End -> true;
in_ranges(Line, [_ | Rest]) -> in_ranges(Line, Rest).

parse_format(undefined) ->
    console;
parse_format("console") ->
    console;
parse_format("json") ->
    json;
parse_format(Other) ->
    rebar_api:warn("Unknown format '~s', defaulting to console", [Other]),
    console.

score(_Killed, 0, _CompileErrors) ->
    0.0;
score(Killed, Total, CompileErrors) ->
    case Total - CompileErrors of
        0 -> 0.0;
        Testable -> (Killed / Testable) * 100
    end.

is_compile_error({compile_error, _}) -> true;
is_compile_error(_) -> false.
