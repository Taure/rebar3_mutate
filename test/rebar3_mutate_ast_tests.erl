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
    MutatedForms = rebar3_mutate_ast:apply_mutation(Forms, First, Ops),
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

mutation_points_line_filter_test() ->
    File = write_temp_module(),
    {ok, _Module, Forms} = rebar3_mutate_ast:parse_file(File, []),
    AllPoints = rebar3_mutate_ast:mutation_points(Forms, rebar3_mutate_operators:all()),
    %% Line 3 is "add(A, B) -> A + B." — should have arithmetic mutations
    Line3Points = rebar3_mutate_ast:mutation_points(Forms, rebar3_mutate_operators:all(), [3]),
    ?assert(length(Line3Points) > 0),
    ?assert(length(Line3Points) =< length(AllPoints)),
    %% All returned points should be on line 3
    lists:foreach(
        fun({mutation_point, _, _, Line, _, _}) ->
            ?assertEqual(3, Line)
        end,
        Line3Points
    ),
    file:delete(File).

mutation_points_line_filter_no_match_test() ->
    File = write_temp_module(),
    {ok, _Module, Forms} = rebar3_mutate_ast:parse_file(File, []),
    %% Line 999 doesn't exist — should return empty
    Points = rebar3_mutate_ast:mutation_points(Forms, rebar3_mutate_operators:all(), [999]),
    ?assertEqual([], Points),
    file:delete(File).

mutation_points_line_filter_multiple_lines_test() ->
    File = write_temp_module(),
    {ok, _Module, Forms} = rebar3_mutate_ast:parse_file(File, []),
    %% Lines 3 and 4 should both have mutations
    Points = rebar3_mutate_ast:mutation_points(Forms, rebar3_mutate_operators:all(), [3, 4]),
    ?assert(length(Points) > 0),
    %% All points should be on lines 3 or 4
    lists:foreach(
        fun({mutation_point, _, _, Line, _, _}) ->
            ?assert(Line =:= 3 orelse Line =:= 4)
        end,
        Points
    ),
    file:delete(File).

function_ranges_test() ->
    File = write_temp_module(),
    {ok, _Module, Forms} = rebar3_mutate_ast:parse_file(File, []),
    Ranges = rebar3_mutate_ast:function_ranges(Forms),
    ?assert(length(Ranges) > 0),
    %% Should find add/2, compare/2, check/1
    FnNames = [Name || {Name, _, _, _} <- Ranges],
    ?assert(lists:member(add, FnNames)),
    ?assert(lists:member(compare, FnNames)),
    ?assert(lists:member(check, FnNames)),
    file:delete(File).

function_ranges_arity_test() ->
    File = write_temp_module(),
    {ok, _Module, Forms} = rebar3_mutate_ast:parse_file(File, []),
    Ranges = rebar3_mutate_ast:function_ranges(Forms),
    AddRange = [R || {add, 2, _, _} = R <- Ranges],
    ?assertEqual(1, length(AddRange)),
    file:delete(File).

%%====================================================================
%% Helpers
%%====================================================================

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
