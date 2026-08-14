-module(rebar3_mutate_runner_tests).

-include_lib("eunit/include/eunit.hrl").

killed_mutant_test() ->
    {Forms, File} = compile_test_module(),
    Ops = [op_arithmetic],
    Points = rebar3_mutate_ast:mutation_points(Forms, Ops),
    [First | _] = Points,
    MutatedForms = rebar3_mutate_ast:apply_mutation(Forms, First),
    Result = rebar3_mutate_runner:run_mutant(mutate_test_target, MutatedForms, eunit, 5000),
    ?assertEqual(killed, Result),
    cleanup(mutate_test_target, File).

survived_mutant_test() ->
    {Forms, File} = compile_untested_module(),
    Ops = [op_arithmetic],
    Points = rebar3_mutate_ast:mutation_points(Forms, Ops),
    case Points of
        [First | _] ->
            MutatedForms = rebar3_mutate_ast:apply_mutation(Forms, First),
            Result = rebar3_mutate_runner:run_mutant(
                mutate_test_untested, MutatedForms, eunit, 5000
            ),
            ?assertEqual(survived, Result);
        [] ->
            ok
    end,
    cleanup(mutate_test_untested, File).

timeout_test() ->
    {Forms, File} = compile_loop_module(),
    Ops = [op_return_value],
    Points = rebar3_mutate_ast:mutation_points(Forms, Ops),
    case Points of
        [First | _] ->
            MutatedForms = rebar3_mutate_ast:apply_mutation(Forms, First),
            Result = rebar3_mutate_runner:run_mutant(mutate_test_loop, MutatedForms, eunit, 1000),
            ?assertEqual(timed_out, Result);
        [] ->
            %% If no mutation points, test the timeout directly with the original forms
            Result = rebar3_mutate_runner:run_mutant(mutate_test_loop, Forms, eunit, 1000),
            ?assertEqual(timed_out, Result)
    end,
    cleanup(mutate_test_loop, File).

compile_error_test() ->
    BrokenForms = [
        {attribute, 1, module, mutate_test_bad},
        {function, 2, foo, 0, [
            {clause, 2, [], [], [{call, 2, {remote, 2, {var, 2, 'X'}, {atom, 2, bar}}, []}]}
        ]},
        {eof, 3}
    ],
    Result = rebar3_mutate_runner:run_mutant(mutate_test_bad, BrokenForms, eunit, 5000),
    ?assertMatch({compile_error, _}, Result).

%%====================================================================
%% Helpers
%%====================================================================

tmp_dir() ->
    filename:join(["/tmp", "rebar3_mutate_runner_test"]).

compile_test_module() ->
    Dir = tmp_dir(),
    filelib:ensure_dir(filename:join(Dir, "dummy")),
    File = filename:join(Dir, "mutate_test_target.erl"),
    Src =
        "-module(mutate_test_target).\n"
        "-export([add/2]).\n"
        "-ifdef(TEST).\n"
        "-include_lib(\"eunit/include/eunit.hrl\").\n"
        "add_test() -> ?assertEqual(5, add(2, 3)).\n"
        "-endif.\n"
        "add(A, B) -> A + B.\n",
    ok = file:write_file(File, Src),
    {ok, mutate_test_target, Bin} = compile:file(File, [binary, {d, 'TEST'}]),
    {module, mutate_test_target} = code:load_binary(mutate_test_target, File, Bin),
    {ok, _Mod, Forms} = rebar3_mutate_ast:parse_file(File, []),
    {Forms, File}.

compile_untested_module() ->
    Dir = tmp_dir(),
    filelib:ensure_dir(filename:join(Dir, "dummy")),
    File = filename:join(Dir, "mutate_test_untested.erl"),
    Src =
        "-module(mutate_test_untested).\n"
        "-export([add/2, name/0]).\n"
        "-ifdef(TEST).\n"
        "-include_lib(\"eunit/include/eunit.hrl\").\n"
        "name_test() -> ?assertEqual(hello, name()).\n"
        "-endif.\n"
        "add(A, B) -> A + B.\n"
        "name() -> hello.\n",
    ok = file:write_file(File, Src),
    {ok, mutate_test_untested, Bin} = compile:file(File, [binary, {d, 'TEST'}]),
    {module, mutate_test_untested} = code:load_binary(mutate_test_untested, File, Bin),
    {ok, _Mod, Forms} = rebar3_mutate_ast:parse_file(File, []),
    {Forms, File}.

compile_loop_module() ->
    Dir = tmp_dir(),
    filelib:ensure_dir(filename:join(Dir, "dummy")),
    File = filename:join(Dir, "mutate_test_loop.erl"),
    Src =
        "-module(mutate_test_loop).\n"
        "-export([loop/0]).\n"
        "-ifdef(TEST).\n"
        "-include_lib(\"eunit/include/eunit.hrl\").\n"
        "loop_test() -> loop().\n"
        "-endif.\n"
        "loop() -> loop().\n",
    ok = file:write_file(File, Src),
    {ok, mutate_test_loop, Bin} = compile:file(File, [binary, {d, 'TEST'}]),
    {module, mutate_test_loop} = code:load_binary(mutate_test_loop, File, Bin),
    {ok, _Mod, Forms} = rebar3_mutate_ast:parse_file(File, []),
    {Forms, File}.

cleanup(Module, File) ->
    code:purge(Module),
    code:delete(Module),
    file:delete(File).
