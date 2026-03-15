-module(rebar3_mutate_report).

-export([format/2, format_json/1, format_mte/2, format_html/1]).

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

-spec format_mte(
    [{atom(), [{rebar3_mutate_ast:mutation_point(), term()}]}],
    #{atom() => file:filename()}
) -> iodata().
format_mte(AllResults, SourceFiles) ->
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
    High = 80,
    Low = 60,

    Files = lists:map(
        fun({Module, Results}) ->
            FilePath = atom_to_list(Module) ++ ".erl",
            Source = read_source(Module, SourceFiles),
            {MutantsList, _} = lists:mapfoldl(
                fun({Point, Status}, Counter) ->
                    {mte_mutant(Point, Status, Counter), Counter + 1}
                end,
                0,
                Results
            ),
            {
                iolist_to_binary(FilePath),
                encode_object([
                    {<<"language">>, <<"erlang">>},
                    {<<"source">>, Source},
                    {<<"mutants">>, {array, MutantsList}}
                ])
            }
        end,
        AllResults
    ),

    FilesObj = encode_dict(Files),

    encode_object([
        {<<"schemaVersion">>, <<"2">>},
        {<<"thresholds">>,
            {raw,
                encode_object([
                    {<<"high">>, High},
                    {<<"low">>, Low}
                ])}},
        {<<"files">>, {raw, FilesObj}},
        {<<"framework">>,
            {raw,
                encode_object([
                    {<<"name">>, <<"rebar3_mutate">>},
                    {<<"version">>, <<"0.4.0">>}
                ])}},
        {<<"performance">>,
            {raw,
                encode_object([
                    {<<"setup">>, 0},
                    {<<"initialRun">>, 0},
                    {<<"mutation">>, 0}
                ])}},
        {<<"config">>,
            {raw,
                encode_object([
                    {<<"overall_score">>, OverallScore},
                    {<<"total_mutants">>, TotalMutants},
                    {<<"total_killed">>, TotalKilled}
                ])}}
    ]).

-spec format_html(iodata()) -> iodata().
format_html(MteJson) ->
    [
        <<
            "<!DOCTYPE html>\n"
            "<html lang=\"en\">\n"
            "<head>\n"
            "  <meta charset=\"utf-8\">\n"
            "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
            "  <title>Mutation Testing Report — rebar3_mutate</title>\n"
            "  <script type=\"module\" src=\"https://cdn.jsdelivr.net/npm/mutation-testing-elements/dist/mutation-test-elements.js\"></script>\n"
            "</head>\n"
            "<body>\n"
            "  <mutation-test-report-app title-postfix=\"rebar3_mutate\">\n"
            "    Your browser doesn't support custom elements.\n"
            "  </mutation-test-report-app>\n"
            "  <script type=\"module\">\n"
            "    const app = document.querySelector('mutation-test-report-app');\n"
            "    app.report = "
        >>,
        MteJson,
        <<
            ";\n"
            "  </script>\n"
            "</body>\n"
            "</html>\n"
        >>
    ].

%%====================================================================
%% Internal — legacy JSON
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

%%====================================================================
%% Internal — mutation-testing-elements
%%====================================================================

read_source(Module, SourceFiles) ->
    case maps:find(Module, SourceFiles) of
        {ok, FilePath} ->
            case file:read_file(FilePath) of
                {ok, Content} -> Content;
                {error, _} -> <<"">>
            end;
        error ->
            <<"">>
    end.

mte_mutant(Point, Status, Counter) ->
    Desc = iolist_to_binary(rebar3_mutate_ast:describe_mutation(Point)),
    {mutation_point, _Idx, Op, Line, _Orig, Mutated} = Point,
    Replacement =
        try
            iolist_to_binary(erl_prettypr:format(Mutated, [{paper, 80}, {ribbon, 60}]))
        catch
            _:_ -> <<"">>
        end,
    MutantId = iolist_to_binary(io_lib:format("~s_~B_~B", [Op, Line, Counter])),
    encode_object([
        {<<"id">>, MutantId},
        {<<"mutatorName">>, atom_to_binary(Op)},
        {<<"replacement">>, Replacement},
        {<<"description">>, Desc},
        {<<"location">>,
            {raw,
                encode_object([
                    {<<"start">>,
                        {raw,
                            encode_object([
                                {<<"line">>, Line},
                                {<<"column">>, 1}
                            ])}},
                    {<<"end">>,
                        {raw,
                            encode_object([
                                {<<"line">>, Line},
                                {<<"column">>, 1}
                            ])}}
                ])}},
        {<<"status">>, mte_status(Status)}
    ]).

mte_status(killed) -> <<"Killed">>;
mte_status(survived) -> <<"Survived">>;
mte_status(timed_out) -> <<"Timeout">>;
mte_status({compile_error, _}) -> <<"CompileError">>.

%%====================================================================
%% Internal — JSON encoder
%%====================================================================

encode_object(Props) ->
    Inner = lists:join(<<",">>, [
        [<<"\"">>, Key, <<"\":">>, encode_value(Val)]
     || {Key, Val} <- Props
    ]),
    [<<"{">>, Inner, <<"}">>].

encode_dict(KVs) ->
    Inner = lists:join(<<",">>, [
        [<<"\"">>, escape_json(Key), <<"\":">>, Val]
     || {Key, Val} <- KVs
    ]),
    [<<"{">>, Inner, <<"}">>].

encode_value(V) when is_integer(V) -> integer_to_binary(V);
encode_value(V) when is_float(V) -> float_to_binary(V, [{decimals, 1}]);
encode_value(V) when is_binary(V) -> [<<"\"">>, escape_json(V), <<"\"">>];
encode_value({array, Items}) -> [<<"[">>, lists:join(<<",">>, Items), <<"]">>];
encode_value({raw, IoData}) -> IoData.

escape_json(Bin) ->
    binary:replace(
        binary:replace(Bin, <<"\\">>, <<"\\\\">>, [global]),
        <<"\"">>,
        <<"\\\"">>,
        [global]
    ).

is_compile_error({compile_error, _}) -> true;
is_compile_error(_) -> false.
