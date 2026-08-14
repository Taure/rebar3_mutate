-module(rebar3_mutate_ast_tests).

-include_lib("eunit/include/eunit.hrl").

parse_and_find_mutations_test() ->
    File = write_temp_module(),
    {ok, test_target, Forms} = rebar3_mutate_ast:parse_file(File, []),
    Points = rebar3_mutate_ast:mutation_points(Forms, rebar3_mutate_operators:all()),
    ?assert(length(Points) > 0),
    file:delete(File).

apply_mutation_compiles_test() ->
    File = write_temp_module(),
    {ok, test_target, Forms} = rebar3_mutate_ast:parse_file(File, []),
    Ops = rebar3_mutate_operators:all(),
    Points = rebar3_mutate_ast:mutation_points(Forms, Ops),
    [First | _] = Points,
    MutatedForms = rebar3_mutate_ast:apply_mutation(Forms, First),
    Result = compile:forms(MutatedForms, [binary, return_errors]),
    ?assertMatch({ok, test_target, _}, Result),
    file:delete(File).

describe_mutation_test() ->
    File = write_temp_module(),
    {ok, _Module, Forms} = rebar3_mutate_ast:parse_file(File, []),
    Points = rebar3_mutate_ast:mutation_points(Forms, rebar3_mutate_operators:all()),
    [First | _] = Points,
    Desc = rebar3_mutate_ast:describe_mutation(First),
    ?assert(iolist_size(Desc) > 0),
    file:delete(File).

mutation_points_respect_operator_filter_test() ->
    File = write_temp_module(),
    {ok, _Module, Forms} = rebar3_mutate_ast:parse_file(File, []),
    AllPoints = rebar3_mutate_ast:mutation_points(Forms, rebar3_mutate_operators:all()),
    ArithOnly = rebar3_mutate_ast:mutation_points(Forms, [op_arithmetic]),
    ?assert(length(ArithOnly) =< length(AllPoints)),
    ?assert(length(ArithOnly) > 0),
    file:delete(File).

eqwalizer_attributes_skipped_test() ->
    File = write_temp_module_with_eqwalizer(),
    {ok, _Module, Forms} = rebar3_mutate_ast:parse_file(File, []),
    Points = rebar3_mutate_ast:mutation_points(Forms, rebar3_mutate_operators:all()),
    Lines = [rebar3_mutate_ast:get_point_line(P) || P <- Points],
    %% Line 3 is the eqwalizer attribute - should not appear
    ?assertNot(lists:member(3, Lines)),
    %% But we should still get mutations from the actual code
    ?assert(length(Points) > 0),
    file:delete(File).

%% Every reported point must actually change the code it says it changes.
%% Before the path-based identity fix, mutation_points/2 and apply_mutation/3
%% counted indices in two separate traversals, so a point could splice the
%% wrong node or nothing at all while still being reported as a real mutant.
every_point_changes_the_source_test() ->
    File = write_module("drift_target", drift_source()),
    {ok, _Module, Forms} = rebar3_mutate_ast:parse_file(File, []),
    Ops = rebar3_mutate_operators:all(),
    Points = rebar3_mutate_ast:mutation_points(Forms, Ops),
    ?assert(length(Points) > 0),
    Original = function_source(Forms),
    lists:foreach(
        fun(Point) ->
            Mutated = function_source(rebar3_mutate_ast:apply_mutation(Forms, Point)),
            ?assertNotEqual(
                {Original, rebar3_mutate_ast:describe_mutation(Point)},
                {Mutated, rebar3_mutate_ast:describe_mutation(Point)}
            )
        end,
        Points
    ),
    file:delete(File).

qualified_erlang_call_keeps_its_module_test() ->
    File = write_module("drift_target", drift_source()),
    {ok, _Module, Forms} = rebar3_mutate_ast:parse_file(File, []),
    Points = rebar3_mutate_ast:mutation_points(Forms, [op_list]),
    ?assertEqual(1, length(Points)),
    [Point] = Points,
    Desc = lists:flatten(rebar3_mutate_ast:describe_mutation(Point)),
    ?assertNotEqual(nomatch, string:find(Desc, "erlang:tl")),
    file:delete(File).

attributes_are_not_mutated_test() ->
    File = write_module(
        "attr_target",
        "-module(attr_target).\n"
        "-export([add/2]).\n"
        "-record(cfg, {retries = 3}).\n"
        "-spec add(integer(), integer()) -> {ok, integer()}.\n"
        "add(A, B) -> {ok, A + B}.\n"
    ),
    {ok, _Module, Forms} = rebar3_mutate_ast:parse_file(File, []),
    Points = rebar3_mutate_ast:mutation_points(Forms, rebar3_mutate_operators:all()),
    Original = function_source(Forms),
    Inert = [
        P
     || P <- Points, function_source(rebar3_mutate_ast:apply_mutation(Forms, P)) =:= Original
    ],
    ?assertEqual([], Inert),
    file:delete(File).

test_functions_are_not_mutated_test() ->
    File = write_module(
        "tested_target",
        "-module(tested_target).\n"
        "-export([add/2]).\n"
        "-ifdef(TEST).\n"
        "add_test() -> 5 = add(2, 3).\n"
        "-endif.\n"
        "add(A, B) -> A + B.\n"
    ),
    {ok, _Module, Forms} = rebar3_mutate_ast:parse_file(File, []),
    Points = rebar3_mutate_ast:mutation_points(Forms, [op_arithmetic, op_constant]),
    Lines = lists:usort([rebar3_mutate_ast:get_point_line(P) || P <- Points]),
    ?assertEqual([6], Lines),
    file:delete(File).

every_point_reports_a_real_line_test() ->
    File = write_module("attr_target", drift_source()),
    {ok, _Module, Forms} = rebar3_mutate_ast:parse_file(File, []),
    Points = rebar3_mutate_ast:mutation_points(Forms, rebar3_mutate_operators:all()),
    ?assertEqual([], [P || P <- Points, rebar3_mutate_ast:get_point_line(P) =:= 0]),
    ?assertEqual([], [P || P <- Points, rebar3_mutate_ast:get_point_file(P) =:= ""]),
    file:delete(File).

%%====================================================================
%% Helpers
%%====================================================================

drift_source() ->
    "-module(drift_target).\n"
    "-export([f/2]).\n"
    "f(L, N) ->\n"
    "    H = erlang:hd(L),\n"
    "    H + N.\n".

write_module(Name, Content) ->
    Dir = filename:join(["/tmp", "rebar3_mutate_test"]),
    filelib:ensure_dir(filename:join(Dir, "dummy")),
    File = filename:join(Dir, Name ++ ".erl"),
    ok = file:write_file(File, Content),
    File.

function_source(Forms) ->
    lists:flatten([erl_pp:form(F) || F <- Forms, element(1, F) =:= function]).

write_temp_module() ->
    Dir = filename:join(["/tmp", "rebar3_mutate_test"]),
    filelib:ensure_dir(filename:join(Dir, "dummy")),
    File = filename:join(Dir, "test_target.erl"),
    Content =
        "-module(test_target).\n"
        "-export([add/2, compare/2, check/1]).\n"
        "add(A, B) -> A + B.\n"
        "compare(A, B) when A > B -> greater;\n"
        "compare(_, _) -> other.\n"
        "check(X) -> X =:= ok andalso true.\n",
    ok = file:write_file(File, Content),
    File.

write_temp_module_with_eqwalizer() ->
    Dir = filename:join(["/tmp", "rebar3_mutate_test"]),
    filelib:ensure_dir(filename:join(Dir, "dummy")),
    File = filename:join(Dir, "test_target.erl"),
    Content =
        "-module(test_target).\n"
        "-export([add/2]).\n"
        "-eqwalizer(fixme).\n"
        "add(A, B) -> A + B.\n",
    ok = file:write_file(File, Content),
    File.
