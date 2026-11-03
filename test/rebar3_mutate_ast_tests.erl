-module(rebar3_mutate_ast_tests).

-include_lib("eunit/include/eunit.hrl").

parse_and_find_mutations_test() ->
    File = write_temp_module(),
    try
        {ok, test_target, Forms} = rebar3_mutate_ast:parse_file(
            File, rebar3_mutate_opts:epp([], [])
        ),
        Points = rebar3_mutate_ast:mutation_points(Forms, rebar3_mutate_operators:all()),
        ?assert(length(Points) > 0)
    after
        remove(File)
    end.

apply_mutation_compiles_test() ->
    File = write_temp_module(),
    try
        {ok, test_target, Forms} = rebar3_mutate_ast:parse_file(
            File, rebar3_mutate_opts:epp([], [])
        ),
        Ops = rebar3_mutate_operators:all(),
        Points = rebar3_mutate_ast:mutation_points(Forms, Ops),
        [First | _] = Points,
        MutatedForms = rebar3_mutate_ast:apply_mutation(Forms, First),
        ?assertMatch({ok, _}, rebar3_mutate_runner:compile_mutant(test_target, MutatedForms))
    after
        remove(File)
    end.

describe_mutation_test() ->
    File = write_temp_module(),
    try
        {ok, _Module, Forms} = rebar3_mutate_ast:parse_file(File, rebar3_mutate_opts:epp([], [])),
        Points = rebar3_mutate_ast:mutation_points(Forms, rebar3_mutate_operators:all()),
        [First | _] = Points,
        Desc = rebar3_mutate_ast:describe_mutation(First),
        ?assert(iolist_size(Desc) > 0)
    after
        remove(File)
    end.

mutation_points_respect_operator_filter_test() ->
    File = write_temp_module(),
    try
        {ok, _Module, Forms} = rebar3_mutate_ast:parse_file(File, rebar3_mutate_opts:epp([], [])),
        AllPoints = rebar3_mutate_ast:mutation_points(Forms, rebar3_mutate_operators:all()),
        ArithOnly = rebar3_mutate_ast:mutation_points(Forms, [op_arithmetic]),
        ?assert(length(ArithOnly) =< length(AllPoints)),
        ?assert(length(ArithOnly) > 0)
    after
        remove(File)
    end.

eqwalizer_attributes_skipped_test() ->
    File = write_temp_module_with_eqwalizer(),
    try
        {ok, _Module, Forms} = rebar3_mutate_ast:parse_file(File, rebar3_mutate_opts:epp([], [])),
        Points = rebar3_mutate_ast:mutation_points(Forms, rebar3_mutate_operators:all()),
        Lines = [rebar3_mutate_ast:get_point_line(P) || P <- Points],
        %% Line 3 is the eqwalizer attribute - should not appear
        ?assertNot(lists:member(3, Lines)),
        %% But we should still get mutations from the actual code
        ?assert(length(Points) > 0)
    after
        remove(File)
    end.

%% Every reported point must actually change the code it says it changes.
%% Before the path-based identity fix, mutation_points/2 and apply_mutation/3
%% counted indices in two separate traversals, so a point could splice the
%% wrong node or nothing at all while still being reported as a real mutant.
every_point_changes_the_source_test() ->
    File = write_module("drift_target", drift_source()),
    try
        {ok, _Module, Forms} = rebar3_mutate_ast:parse_file(File, rebar3_mutate_opts:epp([], [])),
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
        )
    after
        remove(File)
    end.

qualified_erlang_call_keeps_its_module_test() ->
    File = write_module("drift_target", drift_source()),
    try
        {ok, _Module, Forms} = rebar3_mutate_ast:parse_file(File, rebar3_mutate_opts:epp([], [])),
        Points = rebar3_mutate_ast:mutation_points(Forms, [op_list]),
        ?assertEqual(1, length(Points)),
        [Point] = Points,
        Desc = lists:flatten(rebar3_mutate_ast:describe_mutation(Point)),
        ?assertNotEqual(nomatch, string:find(Desc, "erlang:tl"))
    after
        remove(File)
    end.

attributes_are_not_mutated_test() ->
    File = write_module(
        "attr_target",
        "-module(attr_target).\n"
        "-export([add/2]).\n"
        "-record(cfg, {retries = 3}).\n"
        "-spec add(integer(), integer()) -> {ok, integer()}.\n"
        "add(A, B) -> {ok, A + B}.\n"
    ),
    try
        {ok, _Module, Forms} = rebar3_mutate_ast:parse_file(File, rebar3_mutate_opts:epp([], [])),
        Points = rebar3_mutate_ast:mutation_points(Forms, rebar3_mutate_operators:all()),
        Original = function_source(Forms),
        Inert = [
            P
         || P <- Points, function_source(rebar3_mutate_ast:apply_mutation(Forms, P)) =:= Original
        ],
        ?assertEqual([], Inert)
    after
        remove(File)
    end.

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
    try
        {ok, _Module, Forms} = rebar3_mutate_ast:parse_file(File, rebar3_mutate_opts:epp([], [])),
        Points = rebar3_mutate_ast:mutation_points(Forms, [op_arithmetic, op_constant]),
        Lines = lists:usort([rebar3_mutate_ast:get_point_line(P) || P <- Points]),
        ?assertEqual([6], Lines)
    after
        remove(File)
    end.

logger_macro_scaffolding_is_not_mutated_test() ->
    File = write_module(
        "logging_target",
        "-module(logging_target).\n"
        "-export([f/1]).\n"
        "-include_lib(\"kernel/include/logger.hrl\").\n"
        "f(N) ->\n"
        "    ?LOG_WARNING(#{event => f, n => N}),\n"
        "    ?LOG_INFO(\"n ~p\", [N]),\n"
        "    ?LOG_ERROR(\"n ~p\", [N], #{domain => [app]}),\n"
        "    ?LOG(notice, #{event => g}),\n"
        "    N * 2.\n"
    ),
    try
        {ok, _Module, Forms} = rebar3_mutate_ast:parse_file(File, rebar3_mutate_opts:epp([], [])),
        Points = rebar3_mutate_ast:mutation_points(Forms, rebar3_mutate_operators:all()),
        ?assertEqual([9], lists:usort([rebar3_mutate_ast:get_point_line(P) || P <- Points]))
    after
        remove(File)
    end.

%% A call inside a log report still runs, so it is code a test can pin down.
logger_macro_arguments_are_mutated_test() ->
    File = write_module(
        "logging_arguments_target",
        "-module(logging_arguments_target).\n"
        "-export([f/1]).\n"
        "-include_lib(\"kernel/include/logger.hrl\").\n"
        "f(Amount) ->\n"
        "    ?LOG_DEBUG(#{charged => charge(Amount * 2)}),\n"
        "    ok.\n"
        "charge(X) -> X.\n"
    ),
    try
        {ok, Module, Forms} = rebar3_mutate_ast:parse_file(File, rebar3_mutate_opts:epp([], [])),
        Points = rebar3_mutate_ast:mutation_points(Forms, [op_arithmetic, op_constant]),
        ?assertEqual(
            [{5, op_arithmetic}, {5, op_constant}, {5, op_constant}, {5, op_constant}],
            lists:sort([
                {rebar3_mutate_ast:get_point_line(P), rebar3_mutate_ast:get_point_operator(P)}
             || P <- Points
            ])
        ),
        [
            ?assertMatch(
                {ok, _},
                rebar3_mutate_runner:compile_mutant(
                    Module, rebar3_mutate_ast:apply_mutation(Forms, P)
                )
            )
         || P <- Points
        ]
    after
        remove(File)
    end.

logger_macro_level_expression_is_mutated_once_test() ->
    File = write_module(
        "logging_level_target",
        "-module(logging_level_target).\n"
        "-export([f/1]).\n"
        "-include_lib(\"kernel/include/logger.hrl\").\n"
        "f(N) ->\n"
        "    ?LOG(level(N), #{n => N}).\n"
        "level(_) -> info.\n"
    ),
    try
        {ok, _Module, Forms} = rebar3_mutate_ast:parse_file(File, rebar3_mutate_opts:epp([], [])),
        [Point] = rebar3_mutate_ast:mutation_points(Forms, [op_statement_delete]),
        Description = lists:flatten(rebar3_mutate_ast:describe_mutation(Point)),
        ?assertNotEqual(nomatch, string:find(Description, "level(N) -> ok"))
    after
        remove(File)
    end.

handwritten_logger_allow_case_is_mutated_test() ->
    File = write_module(
        "logging_handwritten_target",
        "-module(logging_handwritten_target).\n"
        "-export([f/1]).\n"
        "f(N) ->\n"
        "    case logger:allow(info, ?MODULE) of\n"
        "        true -> N + 1;\n"
        "        false -> ok\n"
        "    end.\n"
    ),
    try
        {ok, _Module, Forms} = rebar3_mutate_ast:parse_file(File, rebar3_mutate_opts:epp([], [])),
        Points = rebar3_mutate_ast:mutation_points(Forms, [op_arithmetic]),
        ?assertEqual([5], [rebar3_mutate_ast:get_point_line(P) || P <- Points])
    after
        remove(File)
    end.

%% Each case is one step away from the macro's shape, so its true/false
%% patterns are ordinary code and op_boolean mutates both.
logger_macro_near_misses_are_mutated_test() ->
    File = write_module(
        "logging_near_miss_target",
        "-module(logging_near_miss_target).\n"
        "-export([plain/2, three_clauses/1, false_not_ok/1]).\n"
        "plain(X, N) ->\n"
        "    case X of\n"
        "        true -> N + 1;\n"
        "        false -> ok\n"
        "    end.\n"
        "three_clauses(N) ->\n"
        "    case logger:allow(info, ?MODULE) of\n"
        "        true -> erlang:apply(logger, macro_log, [#{}, info, N]);\n"
        "        false -> ok;\n"
        "        _ -> N\n"
        "    end.\n"
        "false_not_ok(N) ->\n"
        "    case logger:allow(info, ?MODULE) of\n"
        "        true -> erlang:apply(logger, macro_log, [#{}, info, N]);\n"
        "        false -> N\n"
        "    end.\n"
    ),
    try
        {ok, _Module, Forms} = rebar3_mutate_ast:parse_file(File, rebar3_mutate_opts:epp([], [])),
        Points = rebar3_mutate_ast:mutation_points(Forms, [op_boolean]),
        ?assertEqual(
            [5, 6, 10, 11, 16, 17],
            lists:sort([rebar3_mutate_ast:get_point_line(P) || P <- Points])
        )
    after
        remove(File)
    end.

every_point_reports_a_real_line_test() ->
    File = write_module("attr_target", drift_source()),
    try
        {ok, _Module, Forms} = rebar3_mutate_ast:parse_file(File, rebar3_mutate_opts:epp([], [])),
        Points = rebar3_mutate_ast:mutation_points(Forms, rebar3_mutate_operators:all()),
        ?assertEqual([], [P || P <- Points, rebar3_mutate_ast:get_point_line(P) =:= 0]),
        ?assertEqual([], [P || P <- Points, rebar3_mutate_ast:get_point_file(P) =:= ""])
    after
        remove(File)
    end.

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
    Dir = rebar3_mutate_tmp:dir(),
    File = filename:join(Dir, Name ++ ".erl"),
    ok = file:write_file(File, Content),
    File.

remove(File) ->
    rebar3_mutate_tmp:remove(filename:dirname(File)).

function_source(Forms) ->
    lists:flatten([erl_pp:form(F) || F <- Forms, element(1, F) =:= function]).

write_temp_module() ->
    write_module(
        "test_target",
        "-module(test_target).\n"
        "-export([add/2, compare/2, check/1]).\n"
        "add(A, B) -> A + B.\n"
        "compare(A, B) when A > B -> greater;\n"
        "compare(_, _) -> other.\n"
        "check(X) -> X =:= ok andalso true.\n"
    ).

write_temp_module_with_eqwalizer() ->
    write_module(
        "test_target",
        "-module(test_target).\n"
        "-export([add/2]).\n"
        "-eqwalizer(fixme).\n"
        "add(A, B) -> A + B.\n"
    ).

%% A function behind -ifdef used to resolve to the branch the project does not
%% build, so the plugin mutated code that never ships and scored the module
%% without saying so.
respects_project_defines_test() ->
    File = write_module(
        "gated_target",
        "-module(gated_target).\n"
        "-export([f/1]).\n"
        "-ifdef(FEATURE_X).\n"
        "f(N) -> N * 2.\n"
        "-else.\n"
        "f(_) -> not_available.\n"
        "-endif.\n"
    ),
    try
        Without = rebar3_mutate_ast:parse_file(File, rebar3_mutate_opts:epp([], [])),
        {ok, _, PlainForms} = Without,
        ?assertEqual([6], [Line || {function, Line, f, 1, _} <- PlainForms]),

        With = rebar3_mutate_ast:parse_file(
            File, rebar3_mutate_opts:epp([{d, 'FEATURE_X'}], [])
        ),
        {ok, _, GatedForms} = With,
        ?assertEqual([4], [Line || {function, Line, f, 1, _} <- GatedForms]),
        Points = rebar3_mutate_ast:mutation_points(GatedForms, rebar3_mutate_operators:all()),
        ?assertEqual([4], lists:usort([rebar3_mutate_ast:get_point_line(P) || P <- Points]))
    after
        remove(File)
    end.

%% epp answers {ok, Forms} for an unresolvable include, embedding an error form
%% and dropping the functions around it. Scoring what is left is a wrong number.
incomplete_parse_is_rejected_test() ->
    File = write_module(
        "broken_target",
        "-module(broken_target).\n"
        "-export([f/0]).\n"
        "-include(\"no_such_file_anywhere.hrl\").\n"
        "f() -> ok.\n"
    ),
    try
        ?assertMatch(
            {error, {incomplete_parse, _}},
            rebar3_mutate_ast:parse_file(File, rebar3_mutate_opts:epp([], []))
        )
    after
        remove(File)
    end.
