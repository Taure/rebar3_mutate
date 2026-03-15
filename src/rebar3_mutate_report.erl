-module(rebar3_mutate_report).

-export([format/2, format_json/1]).

-spec format(atom(), [
    {rebar3_mutate_ast:mutation_point(), killed | survived | timed_out | {compile_error, term()}}
]) -> ok.
format(Module, Results) ->
    Total = length(Results),
    Killed = length([R || {_, R} <- Results, R =:= killed]),
    Survived = length([R || {_, R} <- Results, R =:= survived]),
    TimedOut = length([R || {_, R} <- Results, R =:= timed_out]),
    CompileErrors = length([R || {_, R} <- Results, is_compile_error(R)]),
    Score =
        case Total - CompileErrors of
            0 -> 0.0;
            Testable -> (Killed / Testable) * 100
        end,

    rebar_api:info("~n~s", [string:copies("=", 60)]),
    rebar_api:info("Module: ~s (~B mutants, ~B killed, ~B survived, ~B timed out~s)", [
        Module,
        Total,
        Killed,
        Survived,
        TimedOut,
        case CompileErrors of
            0 -> "";
            N -> io_lib:format(", ~B compile errors", [N])
        end
    ]),
    rebar_api:info("Score:  ~.1f%", [Score]),

    case [R || {_, S} = R <- Results, S =:= survived] of
        [] ->
            ok;
        SurvivedList ->
            rebar_api:info("~nSurviving mutants:", []),
            lists:foreach(
                fun({Point, _}) ->
                    Desc = rebar3_mutate_ast:describe_mutation(Point),
                    rebar_api:info("  ~s", [Desc])
                end,
                SurvivedList
            )
    end,

    case [R || {_, S} = R <- Results, S =:= timed_out] of
        [] ->
            ok;
        TimedOutList ->
            rebar_api:info("~nTimed out mutants:", []),
            lists:foreach(
                fun({Point, _}) ->
                    Desc = rebar3_mutate_ast:describe_mutation(Point),
                    rebar_api:info("  ~s", [Desc])
                end,
                TimedOutList
            )
    end,

    rebar_api:info("~s~n", [string:copies("=", 60)]),
    ok.

-spec format_json([{atom(), [{rebar3_mutate_ast:mutation_point(), term()}]}]) -> iodata().
format_json(AllResults) ->
    Modules = lists:map(fun({Module, Results}) -> module_json(Module, Results) end, AllResults),
    TotalKilled = lists:sum([length([R || {_, R} <- Rs, R =:= killed]) || {_, Rs} <- AllResults]),
    TotalMutants = lists:sum([length(Rs) || {_, Rs} <- AllResults]),
    TotalCompileErrors = lists:sum([
        length([R || {_, R} <- Rs, is_compile_error(R)])
     || {_, Rs} <- AllResults
    ]),
    OverallScore =
        case TotalMutants - TotalCompileErrors of
            0 -> 0.0;
            Testable -> (TotalKilled / Testable) * 100
        end,
    encode_object([
        {<<"overall_score">>, OverallScore},
        {<<"total_mutants">>, TotalMutants},
        {<<"total_killed">>, TotalKilled},
        {<<"modules">>, {array, Modules}}
    ]).

%%====================================================================
%% Internal
%%====================================================================

module_json(Module, Results) ->
    Total = length(Results),
    Killed = length([R || {_, R} <- Results, R =:= killed]),
    Survived = length([R || {_, R} <- Results, R =:= survived]),
    TimedOut = length([R || {_, R} <- Results, R =:= timed_out]),
    CompileErrors = length([R || {_, R} <- Results, is_compile_error(R)]),
    Score =
        case Total - CompileErrors of
            0 -> 0.0;
            Testable -> (Killed / Testable) * 100
        end,
    SurvivingMutants = [
        encode_object([
            {<<"description">>, iolist_to_binary(rebar3_mutate_ast:describe_mutation(P))}
        ])
     || {P, S} <- Results, S =:= survived
    ],
    TimedOutMutants = [
        encode_object([
            {<<"description">>, iolist_to_binary(rebar3_mutate_ast:describe_mutation(P))}
        ])
     || {P, S} <- Results, S =:= timed_out
    ],
    encode_object([
        {<<"module">>, atom_to_binary(Module)},
        {<<"total">>, Total},
        {<<"killed">>, Killed},
        {<<"survived">>, Survived},
        {<<"timed_out">>, TimedOut},
        {<<"compile_errors">>, CompileErrors},
        {<<"score">>, Score},
        {<<"surviving_mutants">>, {array, SurvivingMutants}},
        {<<"timed_out_mutants">>, {array, TimedOutMutants}}
    ]).

%% Minimal JSON encoder (no deps needed)
encode_object(Props) ->
    Inner = lists:join(<<",">>, [
        [<<"\"">>, Key, <<"\":">>, encode_value(Val)]
     || {Key, Val} <- Props
    ]),
    [<<"{">>, Inner, <<"}">>].

encode_value(V) when is_integer(V) -> integer_to_binary(V);
encode_value(V) when is_float(V) -> float_to_binary(V, [{decimals, 1}]);
encode_value(V) when is_binary(V) -> [<<"\"">>, escape_json(V), <<"\"">>];
encode_value({array, Items}) -> [<<"[">>, lists:join(<<",">>, Items), <<"]">>].

escape_json(Bin) ->
    binary:replace(
        binary:replace(Bin, <<"\\">>, <<"\\\\">>, [global]),
        <<"\"">>,
        <<"\\\"">>,
        [global]
    ).

is_compile_error({compile_error, _}) -> true;
is_compile_error(_) -> false.
