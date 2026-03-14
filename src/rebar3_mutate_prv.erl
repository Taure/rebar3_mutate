-module(rebar3_mutate_prv).

-behaviour(provider).

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, mutate).
-define(DEPS, [{default, app_discovery}, {default, compile}]).

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
            {timeout, $t, "timeout", integer, "Per-mutant timeout in ms (default: 5000)"},
            {operators, $o, "operators", string,
                "Operators to use, comma-separated (default: all). "
                "Available: op_arithmetic, op_relational, op_boolean, op_return_value"}
        ]},
        {short_desc, "Run mutation testing on project modules"},
        {desc,
            "Generates mutants by applying small code changes and checks whether "
            "your tests detect them. Reports a mutation score and lists surviving mutants."}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.

do(State) ->
    {Args, _} = rebar_state:command_parsed_args(State),
    Timeout = proplists:get_value(timeout, Args, 5000),
    Operators = parse_operators(proplists:get_value(operators, Args, undefined)),
    TargetModules = parse_modules(proplists:get_value(module, Args, undefined)),

    Apps = rebar_state:project_apps(State),
    AllResults = lists:foldl(
        fun(AppInfo, Acc) ->
            AppDir = rebar_app_info:dir(AppInfo),
            SrcDir = filename:join(AppDir, "src"),
            IncludeDir = filename:join(AppDir, "include"),
            SrcFiles = find_source_files(SrcDir, TargetModules),
            lists:foldl(
                fun(File, InnerAcc) ->
                    case process_file(File, [IncludeDir, AppDir], Operators, Timeout) of
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

    lists:foreach(
        fun({Module, Results}) ->
            rebar3_mutate_report:format(Module, Results)
        end,
        lists:reverse(AllResults)
    ),

    rebar_api:info("~nOverall: ~B/~B mutants killed", [TotalKilled, TotalMutants]),
    {ok, State}.

format_error(Reason) ->
    io_lib:format("~p", [Reason]).

%%====================================================================
%% Internal
%%====================================================================

process_file(File, IncludeDirs, Operators, Timeout) ->
    case rebar3_mutate_ast:parse_file(File, IncludeDirs) of
        {ok, Module, Forms} ->
            Points = rebar3_mutate_ast:mutation_points(Forms, Operators),
            rebar_api:info("~s: ~B mutation points found", [Module, length(Points)]),
            Results = lists:map(
                fun(Point) ->
                    MutatedForms = rebar3_mutate_ast:apply_mutation(Forms, Point, Operators),
                    Result = rebar3_mutate_runner:run_mutant(
                        Module, MutatedForms, eunit, Timeout
                    ),
                    {Point, Result}
                end,
                Points
            ),
            {ok, Module, Results};
        {error, _} = Err ->
            Err
    end.

find_source_files(SrcDir, all) ->
    filelib:wildcard(filename:join(SrcDir, "*.erl"));
find_source_files(SrcDir, Modules) ->
    lists:filtermap(
        fun(Mod) ->
            File = filename:join(SrcDir, atom_to_list(Mod) ++ ".erl"),
            case filelib:is_file(File) of
                true -> {true, File};
                false -> false
            end
        end,
        Modules
    ).

parse_modules(undefined) -> all;
parse_modules(Str) -> [list_to_atom(string:trim(S)) || S <- string:split(Str, ",", all)].

parse_operators(undefined) ->
    rebar3_mutate_operators:all();
parse_operators(Str) ->
    [list_to_atom(string:trim(S)) || S <- string:split(Str, ",", all)].
