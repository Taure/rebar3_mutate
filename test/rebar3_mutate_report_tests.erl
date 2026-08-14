-module(rebar3_mutate_report_tests).

-include_lib("eunit/include/eunit.hrl").

format_json_empty_test() ->
    Json = iolist_to_binary(rebar3_mutate_report:format_json([])),
    ?assertMatch(<<"{", _/binary>>, Json),
    ?assert(binary:match(Json, <<"\"overall_score\"">>) =/= nomatch),
    ?assert(binary:match(Json, <<"\"total_mutants\":0">>) =/= nomatch).

format_json_with_results_test() ->
    Point = make_point(1, op_arithmetic, 10),
    Results = [{test_mod, [{Point, killed}, {Point, survived}]}],
    Json = iolist_to_binary(rebar3_mutate_report:format_json(Results)),
    ?assert(binary:match(Json, <<"\"total_mutants\":2">>) =/= nomatch),
    ?assert(binary:match(Json, <<"\"total_killed\":1">>) =/= nomatch),
    ?assert(binary:match(Json, <<"\"test_mod\"">>) =/= nomatch).

format_json_score_test() ->
    Point = make_point(1, op_arithmetic, 10),
    Results = [{test_mod, [{Point, killed}, {Point, killed}, {Point, survived}]}],
    Json = iolist_to_binary(rebar3_mutate_report:format_json(Results)),
    ?assert(binary:match(Json, <<"66.7">>) =/= nomatch).

format_json_multiline_description_test() ->
    %% Build an expression long enough to span multiple lines when pretty-printed
    Orig = erl_syntax:application(
        erl_syntax:atom(join_with_sep),
        [
            erl_syntax:list_comp(
                erl_syntax:application(
                    erl_syntax:atom(atom_to_binary),
                    [
                        erl_syntax:variable('SomeVeryLongVariableName'),
                        erl_syntax:atom(utf8)
                    ]
                ),
                [
                    erl_syntax:generator(
                        erl_syntax:variable('SomeVeryLongVariableName'),
                        erl_syntax:variable('ColumnListVariable')
                    )
                ]
            ),
            erl_syntax:binary([erl_syntax:binary_field(erl_syntax:string("_"))])
        ]
    ),
    Mutated = erl_syntax:atom(ok),
    Point = {mutation_point, [{1, 1}], op_statement_delete, "test_mod.erl", 82, Orig, Mutated},
    Results = [{test_mod, [{Point, survived}]}],
    Json = iolist_to_binary(rebar3_mutate_report:format_json(Results)),
    %% JSON must not contain literal newlines — they must be escaped
    ?assertEqual(nomatch, binary:match(Json, <<"\n">>)),
    ?assert(binary:match(Json, <<"\\n">>) =/= nomatch).

%%====================================================================
%% Helpers
%%====================================================================

make_point(Idx, Op, Line) ->
    Orig = erl_syntax:infix_expr(
        erl_syntax:integer(1), erl_syntax:operator('+'), erl_syntax:integer(2)
    ),
    Mutated = erl_syntax:infix_expr(
        erl_syntax:integer(1), erl_syntax:operator('-'), erl_syntax:integer(2)
    ),
    {mutation_point, [{1, Idx}], Op, "test_mod.erl", Line, Orig, Mutated}.
