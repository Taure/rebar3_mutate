-module(rebar3_mutate_report_tests).

-include_lib("eunit/include/eunit.hrl").

format_json_empty_test() ->
    Json = iolist_to_binary(rebar3_mutate_report:format_json([], [])),
    ?assertMatch(<<"{", _/binary>>, Json),
    ?assertMatch(#{~"total_mutants" := 0}, json:decode(Json)).

format_json_with_results_test() ->
    Point = make_point(op_arithmetic, 10),
    Results = [{test_mod, [{Point, killed}, {Point, survived}]}],
    Decoded = json:decode(iolist_to_binary(rebar3_mutate_report:format_json(Results, []))),
    ?assertMatch(
        #{~"total_mutants" := 2, ~"total_killed" := 1, ~"testable" := 2},
        Decoded
    ),
    [Module] = maps:get(~"modules", Decoded),
    ?assertMatch(#{~"module" := ~"test_mod", ~"survived" := 1}, Module).

format_json_score_test() ->
    Point = make_point(op_arithmetic, 10),
    Results = [{test_mod, [{Point, killed}, {Point, killed}, {Point, survived}]}],
    Decoded = json:decode(iolist_to_binary(rebar3_mutate_report:format_json(Results, []))),
    ?assertMatch(#{~"overall_score" := 66.7}, Decoded).

%% The erlang-ci action extracts the payload with a sed anchor on the first key
%% and then reads it with jq, so key order and strict JSON both matter.
format_json_starts_with_overall_score_test() ->
    Point = make_point(op_arithmetic, 10),
    Json = iolist_to_binary(rebar3_mutate_report:format_json([{test_mod, [{Point, killed}]}], [])),
    ?assertMatch(<<"{\"overall_score\":", _/binary>>, Json).

format_json_multiline_description_test() ->
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
    Point = {mutation_point, [{1, 1}], op_statement_delete, "src/test_mod.erl", 82, Orig, Mutated},
    Json = iolist_to_binary(
        rebar3_mutate_report:format_json([{test_mod, [{Point, survived}]}], [])
    ),
    ?assertEqual(nomatch, binary:match(Json, <<"\n">>)),
    ?assertMatch(#{~"modules" := [_]}, json:decode(Json)).

format_json_reports_mutant_location_test() ->
    Point = make_point(op_arithmetic, 42),
    Json = iolist_to_binary(
        rebar3_mutate_report:format_json([{test_mod, [{Point, survived}]}], [])
    ),
    #{~"modules" := [#{~"surviving_mutants" := [Mutant]}]} = json:decode(Json),
    ?assertMatch(
        #{~"file" := ~"src/test_mod.erl", ~"line" := 42, ~"operator" := ~"op_arithmetic"},
        Mutant
    ).

format_json_reports_skipped_modules_test() ->
    Json = iolist_to_binary(rebar3_mutate_report:format_json([], [{lonely_mod, no_tests}])),
    #{~"skipped_modules" := [Skipped]} = json:decode(Json),
    ?assertMatch(#{~"module" := ~"lonely_mod", ~"reason" := ~"no_tests"}, Skipped).

%%====================================================================
%% Score semantics
%%====================================================================

%% Compile errors and skips never ran a test, so they belong in neither the
%% numerator nor the denominator.
score_excludes_untestable_mutants_test() ->
    Point = make_point(op_arithmetic, 1),
    Counts = rebar3_mutate_report:count([
        {Point, killed},
        {Point, survived},
        {Point, {compile_error, oops}},
        {Point, {skipped, {worker_crash, killed}}}
    ]),
    ?assertEqual(2, rebar3_mutate_report:testable(Counts)),
    ?assertEqual(4, maps:get(total, Counts)),
    ?assertEqual(50.0, rebar3_mutate_report:score(Counts)).

score_of_nothing_testable_is_zero_test() ->
    Point = make_point(op_arithmetic, 1),
    Counts = rebar3_mutate_report:count([{Point, {compile_error, oops}}]),
    ?assertEqual(0, rebar3_mutate_report:testable(Counts)),
    ?assertEqual(0.0, rebar3_mutate_report:score(Counts)).

timed_out_counts_against_the_score_test() ->
    Point = make_point(op_arithmetic, 1),
    Counts = rebar3_mutate_report:count([{Point, killed}, {Point, timed_out}]),
    ?assertEqual(50.0, rebar3_mutate_report:score(Counts)).

%%====================================================================
%% Helpers
%%====================================================================

make_point(Op, Line) ->
    Orig = erl_syntax:infix_expr(
        erl_syntax:integer(1), erl_syntax:operator('+'), erl_syntax:integer(2)
    ),
    Mutated = erl_syntax:infix_expr(
        erl_syntax:integer(1), erl_syntax:operator('-'), erl_syntax:integer(2)
    ),
    {mutation_point, [{1, 1}], Op, "src/test_mod.erl", Line, Orig, Mutated}.
