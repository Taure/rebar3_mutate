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

%%====================================================================
%% MTE format tests
%%====================================================================

format_mte_schema_version_test() ->
    Json = iolist_to_binary(rebar3_mutate_report:format_mte([], #{})),
    ?assert(binary:match(Json, <<"\"schemaVersion\":\"2\"">>) =/= nomatch).

format_mte_thresholds_test() ->
    Json = iolist_to_binary(rebar3_mutate_report:format_mte([], #{})),
    ?assert(binary:match(Json, <<"\"thresholds\"">>) =/= nomatch),
    ?assert(binary:match(Json, <<"\"high\":80">>) =/= nomatch),
    ?assert(binary:match(Json, <<"\"low\":60">>) =/= nomatch).

format_mte_framework_test() ->
    Json = iolist_to_binary(rebar3_mutate_report:format_mte([], #{})),
    ?assert(binary:match(Json, <<"\"name\":\"rebar3_mutate\"">>) =/= nomatch).

format_mte_mutant_status_test() ->
    Point = make_point(1, op_arithmetic, 10),
    Results = [
        {test_mod, [
            {Point, killed},
            {Point, survived},
            {Point, timed_out},
            {Point, {compile_error, some_error}}
        ]}
    ],
    Json = iolist_to_binary(rebar3_mutate_report:format_mte(Results, #{})),
    ?assert(binary:match(Json, <<"\"Killed\"">>) =/= nomatch),
    ?assert(binary:match(Json, <<"\"Survived\"">>) =/= nomatch),
    ?assert(binary:match(Json, <<"\"Timeout\"">>) =/= nomatch),
    ?assert(binary:match(Json, <<"\"CompileError\"">>) =/= nomatch).

format_mte_file_key_test() ->
    Point = make_point(1, op_arithmetic, 10),
    Results = [{my_module, [{Point, killed}]}],
    Json = iolist_to_binary(rebar3_mutate_report:format_mte(Results, #{})),
    ?assert(binary:match(Json, <<"\"my_module.erl\"">>) =/= nomatch).

format_mte_mutant_fields_test() ->
    Point = make_point(1, op_arithmetic, 10),
    Results = [{test_mod, [{Point, killed}]}],
    Json = iolist_to_binary(rebar3_mutate_report:format_mte(Results, #{})),
    ?assert(binary:match(Json, <<"\"mutatorName\"">>) =/= nomatch),
    ?assert(binary:match(Json, <<"\"replacement\"">>) =/= nomatch),
    ?assert(binary:match(Json, <<"\"location\"">>) =/= nomatch),
    ?assert(binary:match(Json, <<"\"status\"">>) =/= nomatch),
    ?assert(binary:match(Json, <<"\"id\"">>) =/= nomatch).

format_mte_language_erlang_test() ->
    Point = make_point(1, op_arithmetic, 10),
    Results = [{test_mod, [{Point, killed}]}],
    Json = iolist_to_binary(rebar3_mutate_report:format_mte(Results, #{})),
    ?assert(binary:match(Json, <<"\"language\":\"erlang\"">>) =/= nomatch).

format_mte_unique_ids_test() ->
    Point = make_point(1, op_arithmetic, 10),
    Results = [{test_mod, [{Point, killed}, {Point, survived}]}],
    Json = iolist_to_binary(rebar3_mutate_report:format_mte(Results, #{})),
    %% Should have _0 and _1 suffixes for uniqueness
    ?assert(binary:match(Json, <<"_10_0">>) =/= nomatch),
    ?assert(binary:match(Json, <<"_10_1">>) =/= nomatch).

format_mte_source_embedding_test() ->
    Dir = "/tmp/rebar3_mutate_mte_test",
    filelib:ensure_dir(filename:join(Dir, "dummy")),
    File = filename:join(Dir, "test_mod.erl"),
    ok = file:write_file(File, "-module(test_mod).\n"),
    Point = make_point(1, op_arithmetic, 10),
    Results = [{test_mod, [{Point, killed}]}],
    SourceFiles = #{test_mod => File},
    Json = iolist_to_binary(rebar3_mutate_report:format_mte(Results, SourceFiles)),
    ?assert(binary:match(Json, <<"-module(test_mod)">>) =/= nomatch),
    file:delete(File).

%%====================================================================
%% HTML report tests
%%====================================================================

format_html_contains_doctype_test() ->
    MteJson = rebar3_mutate_report:format_mte([], #{}),
    Html = iolist_to_binary(rebar3_mutate_report:format_html(MteJson)),
    ?assert(binary:match(Html, <<"<!DOCTYPE html>">>) =/= nomatch).

format_html_contains_mutation_test_report_app_test() ->
    MteJson = rebar3_mutate_report:format_mte([], #{}),
    Html = iolist_to_binary(rebar3_mutate_report:format_html(MteJson)),
    ?assert(binary:match(Html, <<"mutation-test-report-app">>) =/= nomatch).

format_html_embeds_json_test() ->
    Point = make_point(1, op_arithmetic, 10),
    Results = [{test_mod, [{Point, killed}]}],
    MteJson = rebar3_mutate_report:format_mte(Results, #{}),
    Html = iolist_to_binary(rebar3_mutate_report:format_html(MteJson)),
    ?assert(binary:match(Html, <<"schemaVersion">>) =/= nomatch),
    ?assert(binary:match(Html, <<"app.report">>) =/= nomatch).

format_html_loads_cdn_test() ->
    MteJson = rebar3_mutate_report:format_mte([], #{}),
    Html = iolist_to_binary(rebar3_mutate_report:format_html(MteJson)),
    ?assert(binary:match(Html, <<"mutation-testing-elements">>) =/= nomatch).

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
    {mutation_point, Idx, Op, Line, Orig, Mutated}.
