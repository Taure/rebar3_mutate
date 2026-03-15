-module(rebar3_mutate_prv).

-behaviour(provider).

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, mutate).
-define(DEPS, [{default, app_discovery}, {default, compile}]).
-define(DEFAULT_TIMEOUT, 5000).
-define(DEFAULT_WORKERS, erlang:system_info(schedulers)).
-define(TIMEOUT_MULTIPLIER, 5).
-define(MIN_TIMEOUT, 2000).

%% Exit codes (matching cargo-mutants convention)
-define(EXIT_ALL_CAUGHT, 0).
-define(EXIT_USAGE_ERROR, 1).
-define(EXIT_SURVIVED, 2).
-define(EXIT_TIMEOUT, 3).
-define(EXIT_BASELINE_FAILED, 4).

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
                "Per-mutant timeout in ms (default: auto from baseline, fallback " ++
                    integer_to_list(?DEFAULT_TIMEOUT) ++ ")"},
            {operators, $o, "operators", string,
                "Operators to use, comma-separated (default: all). "
                "Available: op_arithmetic, op_relational, op_boolean, op_return_value, "
                "op_statement_delete, op_constant, op_negate_condition, op_list, "
                "op_guard, op_exception, op_map, op_binary, "
                "op_clause_swap, op_receive"},
            {test_framework, $f, "test-framework", string, "Test framework: eunit (default) or ct"},
            {min_score, $s, "min-score", float, "Minimum mutation score (0-100). Fail if below"},
            {format, undefined, "format", string,
                "Output format: console (default), json, mte, or html"},
            {workers, $w, "workers", integer,
                "Number of parallel workers (default: scheduler count)"},
            {diff, $d, "diff", string,
                "Only mutate lines changed vs given base branch (e.g. main)"},
            {skip_baseline, undefined, "skip-baseline", boolean,
                "Skip the baseline test run (assumes tests pass)"},
            {profile, $p, "profile", string, "Use named profile from rebar.config mutate config"},
            {function, undefined, "function", string,
                "Target function(s), format: mod:fun/arity, comma-separated"},
            {cache, undefined, "cache", boolean,
                "Enable result caching across runs (default: false)"},
            {shard, undefined, "shard", string,
                "Shard spec k/n: run shard k of n total (0-indexed)"},
            {html_out, undefined, "html-out", string,
                "Output path for HTML report (default: mutate_report.html)"}
        ]},
        {short_desc, "Run mutation testing on project modules"},
        {desc,
            "Generates mutants by applying small code changes and checks whether "
            "your tests detect them. Reports a mutation score and lists surviving mutants.\n\n"
            "Exit codes:\n"
            "  0 - All mutants caught\n"
            "  1 - Usage error\n"
            "  2 - Some mutants survived (below threshold)\n"
            "  3 - Some mutants timed out\n"
            "  4 - Baseline tests failed\n"}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.

do(State) ->
    {Args, _} = rebar_state:command_parsed_args(State),

    %% Load profile config from rebar.config if specified
    ProfileConfig = load_profile(State, proplists:get_value(profile, Args, undefined)),

    %% Merge: CLI args override profile config
    Operators = parse_operators(
        cli_or_profile(operators, Args, ProfileConfig, undefined)
    ),
    TargetModules = parse_modules(
        cli_or_profile(module, Args, ProfileConfig, undefined)
    ),
    ExcludeModules = parse_modules(
        cli_or_profile(exclude, Args, ProfileConfig, undefined)
    ),
    TestSpec = parse_test_framework(
        cli_or_profile(test_framework, Args, ProfileConfig, undefined)
    ),
    MinScore = cli_or_profile(min_score, Args, ProfileConfig, undefined),
    Format = parse_format(
        cli_or_profile(format, Args, ProfileConfig, undefined)
    ),
    Workers = cli_or_profile(workers, Args, ProfileConfig, ?DEFAULT_WORKERS),
    DiffBase = cli_or_profile(diff, Args, ProfileConfig, undefined),
    SkipBaseline = cli_or_profile(skip_baseline, Args, ProfileConfig, false),
    ExplicitTimeout = cli_or_profile(timeout, Args, ProfileConfig, undefined),
    EnableCache = cli_or_profile(cache, Args, ProfileConfig, false),
    ShardSpec = parse_shard(proplists:get_value(shard, Args, undefined)),
    HtmlOut = proplists:get_value(html_out, Args, "mutate_report.html"),
    FunctionFilter = parse_functions(proplists:get_value(function, Args, undefined)),

    Apps = rebar_state:project_apps(State),
    RootDir = root_dir(Apps),

    %% Collect source files per app
    AppFiles = lists:flatmap(
        fun(AppInfo) ->
            AppDir = rebar_app_info:dir(AppInfo),
            SrcDir = filename:join(AppDir, "src"),
            IncludeDir = filename:join(AppDir, "include"),
            SrcFiles = find_source_files(SrcDir, TargetModules, ExcludeModules),
            [{File, [IncludeDir, AppDir]} || File <- SrcFiles]
        end,
        Apps
    ),

    %% Parse diff if requested
    DiffLines =
        case DiffBase of
            undefined -> undefined;
            Branch -> rebar3_mutate_diff:changed_lines(Branch)
        end,

    %% Run baseline tests (unless skipped)
    BaselineTimeout =
        case ExplicitTimeout of
            undefined -> ?DEFAULT_TIMEOUT * 10;
            T -> T * 10
        end,
    BaselineDurations =
        case SkipBaseline of
            true ->
                rebar_api:info("Skipping baseline test run", []),
                [];
            false ->
                case run_baseline_check(AppFiles, TestSpec, BaselineTimeout) of
                    {ok, Durations} ->
                        Durations;
                    {error, FailedModule} ->
                        rebar_api:error(
                            "Baseline tests failed for ~p. "
                            "Fix your tests before mutation testing.",
                            [FailedModule]
                        ),
                        erlang:halt(?EXIT_BASELINE_FAILED)
                end
        end,

    %% Dynamic timeout: use baseline duration * multiplier, or explicit, or default
    Timeout =
        case ExplicitTimeout of
            undefined ->
                case BaselineDurations of
                    [] ->
                        ?DEFAULT_TIMEOUT;
                    Ds ->
                        MaxDuration = lists:max([D || {_, D} <- Ds]),
                        max(?MIN_TIMEOUT, MaxDuration * ?TIMEOUT_MULTIPLIER)
                end;
            V ->
                V
        end,

    %% Load cache if enabled
    Cache =
        case EnableCache of
            true -> rebar3_mutate_cache:load(RootDir);
            false -> #{}
        end,

    %% Build source file map for MTE source embedding
    SourceFileMap = lists:foldl(
        fun({File, _}, Acc) ->
            Mod = list_to_atom(filename:basename(File, ".erl")),
            Acc#{Mod => File}
        end,
        #{},
        AppFiles
    ),

    %% Build source hash map for cache invalidation
    SourceHashes =
        case EnableCache of
            true ->
                maps:map(fun(_Mod, File) -> rebar3_mutate_cache:file_hash(File) end, SourceFileMap);
            false ->
                #{}
        end,

    %% Run mutation testing
    AllResults = lists:foldl(
        fun({File, IncludeDirs}, Acc) ->
            Mod = list_to_atom(filename:basename(File, ".erl")),
            Hash = maps:get(Mod, SourceHashes, <<>>),
            case
                process_file(
                    File,
                    IncludeDirs,
                    Operators,
                    TestSpec,
                    Timeout,
                    Workers,
                    DiffLines,
                    FunctionFilter,
                    Cache,
                    ShardSpec,
                    Hash
                )
            of
                {ok, Module, Results} ->
                    [{Module, Results} | Acc];
                {ok, Module, skip, _Reason} ->
                    rebar_api:info("~s: no mutation points in scope, skipping", [Module]),
                    Acc;
                {error, Reason} ->
                    rebar_api:warn("Skipping ~s: ~p", [File, Reason]),
                    Acc
            end
        end,
        [],
        AppFiles
    ),

    %% Update cache
    case EnableCache of
        true ->
            NewCache = update_cache(Cache, AllResults, SourceHashes),
            rebar3_mutate_cache:save(RootDir, NewCache);
        false ->
            ok
    end,

    TotalKilled = lists:sum([length([R || {_, R} <- Rs, R =:= killed]) || {_, Rs} <- AllResults]),
    TotalTimedOut = lists:sum([
        length([R || {_, R} <- Rs, R =:= timed_out])
     || {_, Rs} <- AllResults
    ]),
    TotalMutants = lists:sum([length(Rs) || {_, Rs} <- AllResults]),
    TotalCompileErrors = lists:sum([
        length([R || {_, R} <- Rs, is_compile_error(R)])
     || {_, Rs} <- AllResults
    ]),

    OrderedResults = lists:reverse(AllResults),

    case Format of
        console ->
            lists:foreach(
                fun({Module, Results}) ->
                    rebar3_mutate_report:format(Module, Results)
                end,
                OrderedResults
            ),
            rebar_api:info("~nOverall: ~B/~B mutants killed", [TotalKilled, TotalMutants]),
            emit_github_annotations(OrderedResults);
        json ->
            Json = rebar3_mutate_report:format_json(OrderedResults),
            io:put_chars(Json),
            io:nl();
        mte ->
            Json = rebar3_mutate_report:format_mte(OrderedResults, SourceFileMap),
            io:put_chars(Json),
            io:nl();
        html ->
            MteJson = rebar3_mutate_report:format_mte(OrderedResults, SourceFileMap),
            Html = rebar3_mutate_report:format_html(MteJson),
            ok = file:write_file(HtmlOut, Html),
            rebar_api:info("HTML report written to ~s", [HtmlOut]),
            emit_github_annotations(OrderedResults)
    end,

    OverallScore = score(TotalKilled, TotalMutants, TotalCompileErrors),

    %% Determine exit code
    case determine_exit(MinScore, OverallScore, TotalTimedOut) of
        ?EXIT_ALL_CAUGHT ->
            {ok, State};
        ?EXIT_SURVIVED ->
            {error,
                {?MODULE,
                    io_lib:format(
                        "Mutation score ~.1f% is below minimum ~.1f%",
                        [OverallScore, MinScore]
                    )}};
        ?EXIT_TIMEOUT ->
            {error, {?MODULE, io_lib:format("~B mutants timed out", [TotalTimedOut])}}
    end.

format_error(Reason) ->
    io_lib:format("~s", [Reason]).

%%====================================================================
%% Internal — profile loading
%%====================================================================

load_profile(_State, undefined) ->
    [];
load_profile(State, ProfileName) ->
    ProfileAtom = list_to_existing_atom(ProfileName),
    case rebar_state:get(State, mutate, []) of
        Config when is_list(Config) ->
            Profiles = proplists:get_value(profiles, Config, #{}),
            case maps:find(ProfileAtom, Profiles) of
                {ok, ProfileMap} when is_map(ProfileMap) ->
                    maps:to_list(ProfileMap);
                _ ->
                    rebar_api:warn("Profile '~s' not found in mutate config", [ProfileName]),
                    []
            end;
        _ ->
            []
    end.

cli_or_profile(Key, CliArgs, ProfileConfig, Default) ->
    case proplists:get_value(Key, CliArgs, undefined) of
        undefined -> proplists:get_value(Key, ProfileConfig, Default);
        Value -> Value
    end.

%%====================================================================
%% Internal — baseline
%%====================================================================

run_baseline_check(AppFiles, TestSpec, Timeout) ->
    rebar_api:info("Running baseline tests...", []),
    run_baseline_check(AppFiles, TestSpec, Timeout, []).

run_baseline_check([], _TestSpec, _Timeout, Durations) ->
    {ok, Durations};
run_baseline_check([{File, IncludeDirs} | Rest], TestSpec, Timeout, Durations) ->
    case rebar3_mutate_ast:parse_file(File, IncludeDirs) of
        {ok, Module, _Forms} ->
            case rebar3_mutate_runner:run_baseline(TestSpec, Module, Timeout) of
                {ok, Duration} ->
                    rebar_api:info("  ~s: baseline passed (~Bms)", [Module, Duration]),
                    run_baseline_check(Rest, TestSpec, Timeout, [{Module, Duration} | Durations]);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, _} ->
            run_baseline_check(Rest, TestSpec, Timeout, Durations)
    end.

%%====================================================================
%% Internal — mutation processing
%%====================================================================

process_file(
    File,
    IncludeDirs,
    Operators,
    TestSpec,
    Timeout,
    Workers,
    DiffLines,
    FunctionFilter,
    Cache,
    ShardSpec,
    SourceHash
) ->
    case rebar3_mutate_ast:parse_file(File, IncludeDirs) of
        {ok, Module, Forms} ->
            Points0 =
                case DiffLines of
                    undefined ->
                        rebar3_mutate_ast:mutation_points(Forms, Operators);
                    DiffMap ->
                        BaseName = filename:basename(File),
                        case find_matching_diff(BaseName, DiffMap) of
                            {ok, Lines} ->
                                rebar3_mutate_ast:mutation_points(Forms, Operators, Lines);
                            none ->
                                []
                        end
                end,
            Points1 = filter_by_function(Points0, FunctionFilter, Module, Forms),
            Points2 = apply_shard(Points1, ShardSpec),
            case Points2 of
                [] ->
                    {ok, Module, skip, no_points};
                _ ->
                    rebar_api:info("~s: ~B mutation points found", [Module, length(Points2)]),
                    Results = run_with_cache(
                        Points2,
                        Forms,
                        Module,
                        Operators,
                        TestSpec,
                        Timeout,
                        Workers,
                        Cache,
                        SourceHash
                    ),
                    {ok, Module, Results}
            end;
        {error, _} = Err ->
            Err
    end.

filter_by_function(Points, undefined, _Module, _Forms) ->
    Points;
filter_by_function(Points, FunctionSpecs, Module, Forms) ->
    FnRanges = rebar3_mutate_ast:function_ranges(Forms),
    lists:filter(
        fun(Point) ->
            {mutation_point, _, _, Line, _, _} = Point,
            lists:any(
                fun({Mod, Fun, Arity}) ->
                    (Mod =:= Module orelse Mod =:= '_') andalso
                        lists:any(
                            fun({FName, FArity, StartLine, EndLine}) ->
                                FName =:= Fun andalso FArity =:= Arity andalso
                                    Line >= StartLine andalso Line =< EndLine
                            end,
                            FnRanges
                        )
                end,
                FunctionSpecs
            )
        end,
        Points
    ).

apply_shard(Points, undefined) ->
    Points;
apply_shard(Points, {K, N}) ->
    Indexed = lists:zip(lists:seq(0, length(Points) - 1), Points),
    [P || {Idx, P} <- Indexed, Idx rem N =:= K].

run_with_cache(Points, Forms, Module, Operators, TestSpec, Timeout, Workers, Cache, _Hash) when
    map_size(Cache) =:= 0
->
    run_parallel(Points, Forms, Module, Operators, TestSpec, Timeout, Workers);
run_with_cache(Points, Forms, Module, Operators, TestSpec, Timeout, Workers, Cache, Hash) ->
    {Cached, Uncached} = lists:partition(
        fun(Point) ->
            case rebar3_mutate_cache:lookup(Cache, Module, Point, Hash) of
                {hit, killed} -> true;
                _ -> false
            end
        end,
        Points
    ),
    CachedResults = [{P, killed} || P <- Cached],
    case Cached of
        [] -> ok;
        _ -> rebar_api:info("  ~B cached results reused", [length(Cached)])
    end,
    case Uncached of
        [] ->
            CachedResults;
        _ ->
            FreshResults = run_parallel(
                Uncached, Forms, Module, Operators, TestSpec, Timeout, Workers
            ),
            CachedResults ++ FreshResults
    end.

update_cache(Cache, AllResults, SourceHashes) ->
    lists:foldl(
        fun({Module, Results}, Acc) ->
            Hash = maps:get(Module, SourceHashes, <<>>),
            lists:foldl(
                fun({Point, Status}, InnerAcc) ->
                    {mutation_point, _, Op, Line, _, _} = Point,
                    Key = {Module, Op, Line, Hash},
                    InnerAcc#{Key => Status}
                end,
                Acc,
                Results
            )
        end,
        Cache,
        AllResults
    ).

%%====================================================================
%% Internal — parallel execution (work-stealing)
%%====================================================================

run_parallel(Points, Forms, Module, Operators, TestSpec, Timeout, Workers) when Workers > 1 ->
    Parent = self(),
    Ref = make_ref(),
    %% Work-stealing: put all tasks in a queue, workers pull as they finish
    Queue = ets:new(mutate_queue, [ordered_set, public]),
    lists:foldl(
        fun(Point, Idx) ->
            ets:insert(Queue, {Idx, Point}),
            Idx + 1
        end,
        0,
        Points
    ),
    %% Spawn workers
    WorkerPids = [
        spawn_monitor(fun() ->
            worker_loop(Parent, Ref, Queue, Forms, Module, Operators, TestSpec, Timeout)
        end)
     || _ <- lists:seq(1, min(Workers, length(Points)))
    ],
    Results = collect_results(Ref, WorkerPids, []),
    ets:delete(Queue),
    %% Sort by original index
    [R || {_, R} <- lists:keysort(1, Results)];
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

worker_loop(Parent, Ref, Queue, Forms, Module, Operators, TestSpec, Timeout) ->
    case ets:first(Queue) of
        '$end_of_table' ->
            ok;
        Key ->
            case ets:take(Queue, Key) of
                [{Key, Point}] ->
                    MutatedForms = rebar3_mutate_ast:apply_mutation(Forms, Point, Operators),
                    Result = rebar3_mutate_runner:run_mutant(
                        Module, MutatedForms, TestSpec, Timeout
                    ),
                    print_progress(Result),
                    Parent ! {Ref, Key, {Point, Result}},
                    worker_loop(Parent, Ref, Queue, Forms, Module, Operators, TestSpec, Timeout);
                [] ->
                    %% Another worker took this task, try next
                    worker_loop(Parent, Ref, Queue, Forms, Module, Operators, TestSpec, Timeout)
            end
    end.

collect_results(_Ref, [], Acc) ->
    Acc;
collect_results(Ref, Pids, Acc) ->
    receive
        {Ref, Idx, Result} ->
            collect_results(Ref, Pids, [{Idx, Result} | Acc]);
        {'DOWN', MRef, process, _Pid, normal} ->
            collect_results(Ref, lists:keydelete(MRef, 2, Pids), Acc);
        {'DOWN', MRef, process, _Pid, Reason} ->
            rebar_api:warn("Worker crashed: ~p", [Reason]),
            collect_results(Ref, lists:keydelete(MRef, 2, Pids), Acc)
    end.

%%====================================================================
%% Internal — GitHub Actions annotations
%%====================================================================

emit_github_annotations(AllResults) ->
    case os:getenv("GITHUB_ACTIONS") of
        "true" ->
            lists:foreach(
                fun({Module, Results}) ->
                    File = atom_to_list(Module) ++ ".erl",
                    lists:foreach(
                        fun
                            ({Point, survived}) ->
                                {mutation_point, _, _Op, Line, _, _} = Point,
                                Desc = rebar3_mutate_ast:describe_mutation(Point),
                                io:format(
                                    "::warning file=~s,line=~B::Surviving mutant: ~s~n",
                                    [File, Line, Desc]
                                );
                            ({_, _}) ->
                                ok
                        end,
                        Results
                    )
                end,
                AllResults
            );
        _ ->
            ok
    end.

%%====================================================================
%% Internal — file discovery
%%====================================================================

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

find_matching_diff(_BaseName, DiffMap) when map_size(DiffMap) =:= 0 ->
    none;
find_matching_diff(BaseName, DiffMap) ->
    Matches = maps:filter(
        fun(DiffPath, _Lines) ->
            filename:basename(DiffPath) =:= BaseName
        end,
        DiffMap
    ),
    case maps:values(Matches) of
        [] -> none;
        [Lines | _] -> {ok, Lines}
    end.

%%====================================================================
%% Internal — parsers
%%====================================================================

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

parse_format(undefined) ->
    console;
parse_format("console") ->
    console;
parse_format("json") ->
    json;
parse_format("mte") ->
    mte;
parse_format("html") ->
    html;
parse_format(Other) ->
    rebar_api:warn("Unknown format '~s', defaulting to console", [Other]),
    console.

parse_shard(undefined) ->
    undefined;
parse_shard(Str) ->
    case string:split(Str, "/") of
        [KStr, NStr] ->
            K = list_to_integer(string:trim(KStr)),
            N = list_to_integer(string:trim(NStr)),
            {K, N};
        _ ->
            rebar_api:warn("Invalid shard spec '~s', expected k/n", [Str]),
            undefined
    end.

parse_functions(undefined) ->
    undefined;
parse_functions(Str) ->
    Specs = string:split(Str, ",", all),
    lists:map(fun parse_function_spec/1, Specs).

parse_function_spec(Spec) ->
    Trimmed = string:trim(Spec),
    case string:split(Trimmed, ":") of
        [ModStr, FunArity] ->
            Mod = list_to_atom(ModStr),
            parse_fun_arity(Mod, FunArity);
        [FunArity] ->
            parse_fun_arity('_', FunArity)
    end.

parse_fun_arity(Mod, FunArity) ->
    case string:split(FunArity, "/") of
        [FunStr, ArityStr] ->
            {Mod, list_to_atom(string:trim(FunStr)), list_to_integer(string:trim(ArityStr))};
        [FunStr] ->
            {Mod, list_to_atom(string:trim(FunStr)), '_'}
    end.

%%====================================================================
%% Internal — scoring and exit
%%====================================================================

score(_Killed, 0, _CompileErrors) ->
    0.0;
score(Killed, Total, CompileErrors) ->
    case Total - CompileErrors of
        0 -> 0.0;
        Testable -> (Killed / Testable) * 100
    end.

determine_exit(MinScore, OverallScore, TotalTimedOut) ->
    BelowThreshold = MinScore =/= undefined andalso OverallScore < MinScore,
    if
        BelowThreshold ->
            ?EXIT_SURVIVED;
        TotalTimedOut > 0 ->
            ?EXIT_TIMEOUT;
        true ->
            ?EXIT_ALL_CAUGHT
    end.

is_compile_error({compile_error, _}) -> true;
is_compile_error(_) -> false.

print_progress(killed) -> io:put_chars(standard_error, ".");
print_progress(survived) -> io:put_chars(standard_error, "S");
print_progress(timed_out) -> io:put_chars(standard_error, "T");
print_progress({compile_error, _}) -> io:put_chars(standard_error, "E").

root_dir([]) -> ".";
root_dir([AppInfo | _]) -> rebar_app_info:dir(AppInfo).
