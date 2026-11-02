-module(rebar3_mutate_runner_tests).

-include_lib("eunit/include/eunit.hrl").

killed_mutant_test() ->
    {Module, Forms, File} = build(mutate_test_target, tested_source()),
    Ops = [op_arithmetic],
    [First | _] = rebar3_mutate_ast:mutation_points(Forms, Ops),
    MutatedForms = rebar3_mutate_ast:apply_mutation(Forms, First),
    ?assertEqual(killed, rebar3_mutate_runner:run_mutant(Module, MutatedForms, eunit, 5000)),
    cleanup(Module, File).

survived_mutant_test() ->
    {Module, Forms, File} = build(mutate_test_untested, untested_source()),
    Ops = [op_arithmetic],
    [First | _] = rebar3_mutate_ast:mutation_points(Forms, Ops),
    MutatedForms = rebar3_mutate_ast:apply_mutation(Forms, First),
    ?assertEqual(survived, rebar3_mutate_runner:run_mutant(Module, MutatedForms, eunit, 5000)),
    cleanup(Module, File).

timeout_test() ->
    {Module, Forms, File} = build(mutate_test_loop, loop_source()),
    ?assertEqual(timed_out, rebar3_mutate_runner:run_mutant(Module, Forms, eunit, 1000)),
    cleanup(Module, File).

timed_out_run_is_stopped_before_returning_test() ->
    {Module, Forms, File} = build(mutate_test_stuck, tested_source()),
    {Checks, _, ChecksFile} = build(mutate_test_stuck_checks, stuck_checks_source(Module)),
    try
        [First | _] = rebar3_mutate_ast:mutation_points(Forms, [op_arithmetic]),
        MutatedForms = rebar3_mutate_ast:apply_mutation(Forms, First),
        ?assertEqual(
            timed_out,
            rebar3_mutate_runner:run_mutant(Module, MutatedForms, {eunit, [Checks]}, 500)
        ),
        ?assertEqual(undefined, whereis(mutate_test_stuck_test_process)),
        ?assertEqual(undefined, whereis(mutate_test_stuck_helper))
    after
        cleanup(Checks, ChecksFile),
        cleanup(Module, File)
    end.

%% eunit gives each test its own group leader and stops it when the test ends,
%% so an unlinked helper is left pointing at a dead group leader.
helper_of_a_passing_test_is_stopped_test() ->
    {Module, _Forms, File} = build(mutate_test_helper_pass, bare_source()),
    {Checks, _, ChecksFile} = build(mutate_test_helper_pass_checks, helper_source(passing)),
    try
        ?assertMatch({ok, _Ms}, rebar3_mutate_runner:run_baseline(Module, {eunit, [Checks]}, 5000)),
        ?assertEqual(undefined, whereis(mutate_test_helper))
    after
        cleanup(Checks, ChecksFile),
        cleanup(Module, File)
    end.

helper_of_a_test_eunit_timed_out_is_stopped_test() ->
    {Module, _Forms, File} = build(mutate_test_helper_timeout, bare_source()),
    {Checks, _, ChecksFile} = build(mutate_test_helper_timeout_checks, helper_source(blocking)),
    try
        ?assertMatch(
            {failed, tests_failing},
            rebar3_mutate_runner:run_baseline(Module, {eunit, [Checks]}, 5000)
        ),
        ?assertEqual(undefined, whereis(mutate_test_helper))
    after
        cleanup(Checks, ChecksFile),
        cleanup(Module, File)
    end.

completed_run_leaves_no_process_behind_test() ->
    {Module, _Forms, File} = build(mutate_test_no_leak, tested_source()),
    try
        Before = erlang:processes(),
        _ = [rebar3_mutate_runner:run_baseline(Module, eunit, 5000) || _ <- lists:seq(1, 20)],
        ?assert(length(erlang:processes() -- Before) < 3)
    after
        cleanup(Module, File)
    end.

%% A timed-out run left going keeps writing shared state, and the next run's
%% verdict is then decided by the overlap rather than by its own mutant.
abandoned_run_does_not_reach_the_next_run_test() ->
    {Module, Forms, File} = build(mutate_test_abandoned, bare_source()),
    {Writer, _, WriterFile} = build(mutate_test_abandoned_writer, writer_source()),
    {Checks, _, ChecksFile} = build(mutate_test_abandoned_checks, steady_checks_source()),
    ets:new(mutate_test_side_effects, [named_table, public]),
    try
        [First | _] = rebar3_mutate_ast:mutation_points(Forms, [op_arithmetic]),
        MutatedForms = rebar3_mutate_ast:apply_mutation(Forms, First),
        ?assertEqual(
            timed_out,
            rebar3_mutate_runner:run_mutant(Module, MutatedForms, {eunit, [Writer]}, 300)
        ),
        ?assertMatch([{writes, _}], ets:lookup(mutate_test_side_effects, writes)),
        ?assertMatch({ok, _Ms}, rebar3_mutate_runner:run_baseline(Module, {eunit, [Checks]}, 5000))
    after
        ets:delete(mutate_test_side_effects),
        cleanup(Checks, ChecksFile),
        cleanup(Writer, WriterFile),
        cleanup(Module, File)
    end.

%% A setup that starts an application never reaches its cleanup when the run
%% is stopped, and the application's processes are not part of the run.
application_started_by_a_timed_out_run_is_stopped_test() ->
    {Module, Forms, File} = build(mutate_test_app_target, bare_source()),
    {App, _, AppFile} = build(mutate_test_side_app, side_app_source()),
    {Starter, _, StarterFile} = build(mutate_test_app_starter, app_starter_source(App)),
    {Checks, _, ChecksFile} = build(mutate_test_app_checks, steady_checks_source()),
    ok = application:load(
        {application, App, [
            {description, "rebar3_mutate test application"},
            {vsn, "1"},
            {modules, [App]},
            {registered, []},
            {applications, [kernel, stdlib]},
            {mod, {App, []}}
        ]}
    ),
    ets:new(mutate_test_side_effects, [named_table, public]),
    try
        [First | _] = rebar3_mutate_ast:mutation_points(Forms, [op_arithmetic]),
        MutatedForms = rebar3_mutate_ast:apply_mutation(Forms, First),
        ?assertEqual(
            timed_out,
            rebar3_mutate_runner:run_mutant(Module, MutatedForms, {eunit, [Starter]}, 300)
        ),
        ?assertMatch([{writes, _}], ets:lookup(mutate_test_side_effects, writes)),
        ?assertNot(lists:keymember(App, 1, application:which_applications())),
        ?assertMatch({ok, _Ms}, rebar3_mutate_runner:run_baseline(Module, {eunit, [Checks]}, 5000))
    after
        _ = application:stop(App),
        _ = application:unload(App),
        ets:delete(mutate_test_side_effects),
        cleanup(Checks, ChecksFile),
        cleanup(Starter, StarterFile),
        cleanup(App, AppFile),
        cleanup(Module, File)
    end.

%% A child with shutdown => infinity that never exits makes application:stop/1
%% wait forever. The stop is bounded, and past the bound the application is
%% killed so the next run can start it again.
application_whose_shutdown_hangs_is_killed_test_() ->
    {timeout, 60, fun application_whose_shutdown_hangs_is_killed/0}.

application_whose_shutdown_hangs_is_killed() ->
    {Module, Forms, File} = build(mutate_test_hang_target, bare_source()),
    {Child, _, ChildFile} = build(mutate_test_hang_child, hanging_child_source()),
    {App, _, AppFile} = build(mutate_test_hang_app, hanging_app_source(Child)),
    {Starter, _, StarterFile} = build(mutate_test_hang_starter, app_starter_source(App)),
    {Checks, _, ChecksFile} = build(mutate_test_hang_checks, app_start_checks_source(App)),
    ok = application:load(
        {application, App, [
            {description, "rebar3_mutate test application"},
            {vsn, "1"},
            {modules, [App, Child]},
            {registered, []},
            {applications, [kernel, stdlib]},
            {mod, {App, []}}
        ]}
    ),
    try
        [First | _] = rebar3_mutate_ast:mutation_points(Forms, [op_arithmetic]),
        MutatedForms = rebar3_mutate_ast:apply_mutation(Forms, First),
        Start = erlang:monotonic_time(millisecond),
        ?assertEqual(
            timed_out,
            rebar3_mutate_runner:run_mutant(Module, MutatedForms, {eunit, [Starter]}, 300)
        ),
        ?assert(erlang:monotonic_time(millisecond) - Start < 15000),
        ?assertNot(lists:keymember(App, 1, application:which_applications())),
        ?assertEqual(undefined, whereis(mutate_test_hang_child)),
        ?assertMatch({ok, _Ms}, rebar3_mutate_runner:run_baseline(Module, {eunit, [Checks]}, 5000))
    after
        kill_registered([mutate_test_hang_sup, mutate_test_hang_child]),
        await_stopped(App),
        _ = application:unload(App),
        cleanup(Checks, ChecksFile),
        cleanup(Starter, StarterFile),
        cleanup(App, AppFile),
        cleanup(Child, ChildFile),
        cleanup(Module, File)
    end.

%% On OTP 28 application:stop/1 runs inside application_controller, so a test
%% stuck in one leaves the controller unable to answer which_applications/0.
%% The run is still recorded as timed out.
stuck_application_stop_in_a_test_is_timed_out_test_() ->
    {timeout, 60, fun stuck_application_stop_in_a_test_is_timed_out/0}.

stuck_application_stop_in_a_test_is_timed_out() ->
    {Module, Forms, File} = build(mutate_test_busy_target, bare_source()),
    {Child, _, ChildFile} = build(mutate_test_busy_child, hanging_child_source()),
    {App, _, AppFile} = build(mutate_test_busy_app, hanging_app_source(Child)),
    {Checks, _, ChecksFile} = build(mutate_test_busy_checks, app_stopper_source(App)),
    ok = load_test_application(App, [App, Child]),
    ok = application:start(App),
    try
        [First | _] = rebar3_mutate_ast:mutation_points(Forms, [op_arithmetic]),
        MutatedForms = rebar3_mutate_ast:apply_mutation(Forms, First),
        ?assertEqual(
            timed_out,
            rebar3_mutate_runner:run_mutant(Module, MutatedForms, {eunit, [Checks]}, 300)
        )
    after
        kill_registered([mutate_test_hang_sup, mutate_test_hang_child]),
        await_stopped(App),
        _ = application:unload(App),
        cleanup(Checks, ChecksFile),
        cleanup(App, AppFile),
        cleanup(Child, ChildFile),
        cleanup(Module, File)
    end.

applications_running_before_a_timed_out_run_are_left_alone_test() ->
    {Module, Forms, File} = build(mutate_test_app_kept, bare_source()),
    {Checks, _, ChecksFile} = build(mutate_test_app_kept_checks, stuck_checks_source(Module)),
    {ok, Started} = application:ensure_all_started(sasl),
    try
        [First | _] = rebar3_mutate_ast:mutation_points(Forms, [op_arithmetic]),
        MutatedForms = rebar3_mutate_ast:apply_mutation(Forms, First),
        ?assertEqual(
            timed_out,
            rebar3_mutate_runner:run_mutant(Module, MutatedForms, {eunit, [Checks]}, 300)
        ),
        ?assert(lists:keymember(sasl, 1, application:which_applications()))
    after
        _ = [application:stop(A) || A <- lists:reverse(Started)],
        cleanup(Checks, ChecksFile),
        cleanup(Module, File)
    end.

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
%% Isolation and restoration
%%====================================================================

%% A mutant left resident poisons every later mutant and every later module.
original_is_restored_after_a_mutant_runs_test() ->
    {Module, Forms, File} = build(mutate_test_restore, tested_source()),
    ?assertEqual(5, Module:add(2, 3)),
    [First | _] = rebar3_mutate_ast:mutation_points(Forms, [op_arithmetic]),
    MutatedForms = rebar3_mutate_ast:apply_mutation(Forms, First),
    _ = rebar3_mutate_runner:run_mutant(Module, MutatedForms, eunit, 5000),
    ?assertEqual(5, Module:add(2, 3)),
    Path = code:which(Module),
    true = is_list(Path),
    ?assertEqual(".beam", filename:extension(Path)),
    cleanup(Module, File).

original_is_restored_when_the_test_run_raises_test() ->
    {Module, Forms, File} = build(mutate_test_raise, tested_source()),
    {ok, Binary} = rebar3_mutate_runner:compile_mutant(Module, Forms),
    ?assertMatch(
        {skipped, {unknown_test_framework, no_such_framework}},
        rebar3_mutate_runner:load_and_test(Module, Binary, unknown_framework(), 5000)
    ),
    ?assertEqual(5, Module:add(2, 3)),
    cleanup(Module, File).

-spec unknown_framework() -> dynamic().
unknown_framework() ->
    no_such_framework.

unloadable_mutant_is_skipped_not_fatal_test() ->
    {Module, _Forms, File} = build(mutate_test_unloadable, tested_source()),
    {ok, Foreign} = rebar3_mutate_runner:compile_mutant(mutate_test_bad, [
        {attribute, 1, module, mutate_test_bad},
        {eof, 2}
    ]),
    ?assertMatch(
        {skipped, {load_failed, _}},
        rebar3_mutate_runner:load_and_test(Module, Foreign, eunit, 5000)
    ),
    ?assertEqual(5, Module:add(2, 3)),
    cleanup(Module, File).

module_with_no_restorable_original_is_skipped_test() ->
    Forms = [
        {attribute, 1, module, mutate_test_binary_only},
        {attribute, 2, export, [{f, 0}]},
        {function, 3, f, 0, [{clause, 3, [], [], [{atom, 3, ok}]}]},
        {eof, 4}
    ],
    {ok, Binary} = rebar3_mutate_runner:compile_mutant(mutate_test_binary_only, Forms),
    {module, _} = code:load_binary(mutate_test_binary_only, "nofile", Binary),
    ?assertMatch(
        {skipped, {no_original_code, _}},
        rebar3_mutate_runner:load_and_test(mutate_test_binary_only, Binary, eunit, 5000)
    ),
    code:purge(mutate_test_binary_only),
    code:delete(mutate_test_binary_only).

%%====================================================================
%% Baseline
%%====================================================================

%% Without this, one pre-existing failing test makes every mutant read as
%% killed and the run reports a perfect score.
baseline_rejects_a_failing_suite_test() ->
    {Module, _Forms, File} = build(mutate_test_redsuite, red_source()),
    ?assertMatch({failed, tests_failing}, rebar3_mutate_runner:run_baseline(Module, eunit, 5000)),
    cleanup(Module, File).

baseline_accepts_a_green_suite_test() ->
    {Module, _Forms, File} = build(mutate_test_greensuite, tested_source()),
    ?assertMatch({ok, _Ms}, rebar3_mutate_runner:run_baseline(Module, eunit, 5000)),
    cleanup(Module, File).

%% eunit:test/2 answers ok for a module with no tests at all, so a green
%% baseline is not by itself evidence that anything ran.
baseline_reports_a_module_with_no_tests_test() ->
    {Module, _Forms, File} = build(mutate_test_notests, bare_source()),
    ?assertEqual(no_tests, rebar3_mutate_runner:run_baseline(Module, eunit, 5000)),
    ?assertNot(rebar3_mutate_runner:has_tests(Module, eunit)),
    cleanup(Module, File).

has_tests_finds_colocated_test_functions_test() ->
    {Module, _Forms, File} = build(mutate_test_colocated, tested_source()),
    ?assert(rebar3_mutate_runner:has_tests(Module, eunit)),
    cleanup(Module, File).

has_tests_is_false_for_a_missing_ct_suite_test() ->
    ?assertNot(rebar3_mutate_runner:has_tests(whatever, {ct, no_such_SUITE})).

%%====================================================================
%% Mapped eunit test modules
%%====================================================================

has_tests_counts_a_mapped_test_module_test() ->
    {Module, _Forms, File} = build(mutate_test_mapped_has, bare_source()),
    {Checks, _, ChecksFile} = build(mutate_test_mapped_has_checks, checks_source(Module, 5)),
    ?assertNot(rebar3_mutate_runner:has_tests(Module, eunit)),
    ?assert(rebar3_mutate_runner:has_tests(Module, {eunit, [Checks]})),
    ?assert(rebar3_mutate_runner:has_tests(Module, {eunit, [no_such_module_tests, Checks]})),
    cleanup(Checks, ChecksFile),
    cleanup(Module, File).

has_tests_is_false_when_no_mapped_module_exists_test() ->
    {Module, _Forms, File} = build(mutate_test_mapped_missing, bare_source()),
    ?assertNot(rebar3_mutate_runner:has_tests(Module, {eunit, [no_such_module_tests]})),
    ?assertEqual(
        no_tests, rebar3_mutate_runner:run_baseline(Module, {eunit, [no_such_module_tests]}, 5000)
    ),
    cleanup(Module, File).

%% The case the option exists for: a module with no tests of its own whose
%% behaviour is covered by an integration test module.
mapped_tests_kill_a_mutant_the_own_suite_misses_test() ->
    {Module, Forms, File} = build(mutate_test_mapped_kill, bare_source()),
    {Checks, _, ChecksFile} = build(mutate_test_mapped_kill_checks, checks_source(Module, 5)),
    [First | _] = rebar3_mutate_ast:mutation_points(Forms, [op_arithmetic]),
    MutatedForms = rebar3_mutate_ast:apply_mutation(Forms, First),
    ?assertEqual(survived, rebar3_mutate_runner:run_mutant(Module, MutatedForms, eunit, 5000)),
    ?assertEqual(
        killed, rebar3_mutate_runner:run_mutant(Module, MutatedForms, {eunit, [Checks]}, 5000)
    ),
    ?assertEqual(5, Module:add(2, 3)),
    cleanup(Checks, ChecksFile),
    cleanup(Module, File).

mapped_tests_keep_the_modules_own_tests_test() ->
    {Module, Forms, File} = build(mutate_test_mapped_own, tested_source()),
    {Other, _, OtherFile} = build(mutate_test_mapped_own_unrelated, unrelated_checks_source()),
    [First | _] = rebar3_mutate_ast:mutation_points(Forms, [op_arithmetic]),
    MutatedForms = rebar3_mutate_ast:apply_mutation(Forms, First),
    ?assertEqual(
        killed, rebar3_mutate_runner:run_mutant(Module, MutatedForms, {eunit, [Other]}, 5000)
    ),
    cleanup(Other, OtherFile),
    cleanup(Module, File).

listing_the_modules_own_tests_module_runs_it_once_test() ->
    {Module, _Forms, File} = build(mutate_test_dedup, bare_source()),
    {Tests, _, TestsFile} = build(mutate_test_dedup_tests, counting_source(own)),
    {Extra, _, ExtraFile} = build(mutate_test_dedup_extra, counting_source(extra)),
    ets:new(mutate_test_runs, [named_table, public]),
    ets:insert(mutate_test_runs, [{own, 0}, {extra, 0}]),
    ?assertMatch(
        {ok, _Ms},
        rebar3_mutate_runner:run_baseline(Module, {eunit, [Tests, Extra, Module, Extra]}, 5000)
    ),
    ?assertEqual([{own, 1}], ets:lookup(mutate_test_runs, own)),
    ?assertEqual([{extra, 1}], ets:lookup(mutate_test_runs, extra)),
    ets:delete(mutate_test_runs),
    cleanup(Extra, ExtraFile),
    cleanup(Tests, TestsFile),
    cleanup(Module, File).

%% A loadable beam with no test functions must not count, or the baseline is
%% green without running anything.
has_tests_ignores_a_mapped_module_without_tests_test() ->
    {Module, _Forms, File} = build(mutate_test_mapped_vacuous, bare_source()),
    ?assertNot(rebar3_mutate_runner:has_tests(Module, {eunit, [lists]})),
    ?assertEqual(no_tests, rebar3_mutate_runner:run_baseline(Module, {eunit, [lists]}, 5000)),
    cleanup(Module, File).

contributes_tests_reads_exports_from_disk_test() ->
    {Checks, _, ChecksFile} = build(mutate_test_contrib_checks, unrelated_checks_source()),
    ?assert(rebar3_mutate_runner:contributes_tests(Checks)),
    ?assert(rebar3_mutate_runner:contributes_tests(rebar3_mutate_pool)),
    ?assertNot(rebar3_mutate_runner:contributes_tests(lists)),
    ?assertNot(rebar3_mutate_runner:contributes_tests(no_such_module)),
    cleanup(Checks, ChecksFile).

baseline_runs_the_mapped_test_modules_test() ->
    {Module, _Forms, File} = build(mutate_test_mapped_baseline, bare_source()),
    {Green, _, GreenFile} = build(mutate_test_mapped_green_checks, checks_source(Module, 5)),
    {Red, _, RedFile} = build(mutate_test_mapped_red_checks, checks_source(Module, 99)),
    ?assertEqual(no_tests, rebar3_mutate_runner:run_baseline(Module, eunit, 5000)),
    ?assertMatch({ok, _Ms}, rebar3_mutate_runner:run_baseline(Module, {eunit, [Green]}, 5000)),
    ?assertMatch(
        {failed, tests_failing},
        rebar3_mutate_runner:run_baseline(Module, {eunit, [Green, Red]}, 5000)
    ),
    cleanup(Red, RedFile),
    cleanup(Green, GreenFile),
    cleanup(Module, File).

%%====================================================================
%% Helpers
%%====================================================================

tmp_dir() ->
    Dir = filename:join(["/tmp", "rebar3_mutate_runner_test"]),
    filelib:ensure_dir(filename:join(Dir, "dummy")),
    true = code:add_patha(Dir),
    Dir.

tested_source() ->
    "-export([add/2]).\n"
    "-ifdef(TEST).\n"
    "-include_lib(\"eunit/include/eunit.hrl\").\n"
    "add_test() -> ?assertEqual(5, add(2, 3)).\n"
    "-endif.\n"
    "add(A, B) -> A + B.\n".

untested_source() ->
    "-export([add/2, name/0]).\n"
    "-ifdef(TEST).\n"
    "-include_lib(\"eunit/include/eunit.hrl\").\n"
    "name_test() -> ?assertEqual(hello, name()).\n"
    "-endif.\n"
    "add(A, B) -> A + B.\n"
    "name() -> hello.\n".

loop_source() ->
    "-export([loop/0]).\n"
    "-ifdef(TEST).\n"
    "-include_lib(\"eunit/include/eunit.hrl\").\n"
    "loop_test() -> loop().\n"
    "-endif.\n"
    "loop() -> loop().\n".

red_source() ->
    "-export([add/2]).\n"
    "-ifdef(TEST).\n"
    "-include_lib(\"eunit/include/eunit.hrl\").\n"
    "add_test() -> ?assertEqual(99, add(2, 3)).\n"
    "-endif.\n"
    "add(A, B) -> A + B.\n".

bare_source() ->
    "-export([add/2]).\n"
    "add(A, B) -> A + B.\n".

checks_source(Target, Expected) ->
    "-ifdef(TEST).\n"
    "-include_lib(\"eunit/include/eunit.hrl\").\n"
    "add_test() -> ?assertEqual(" ++ integer_to_list(Expected) ++ ", " ++ atom_to_list(Target) ++
        ":add(2, 3)).\n"
        "-endif.\n".

counting_source(Key) ->
    "-ifdef(TEST).\n"
    "-include_lib(\"eunit/include/eunit.hrl\").\n"
    "count_test() -> ets:update_counter(mutate_test_runs, " ++ atom_to_list(Key) ++
        ", 1).\n"
        "-endif.\n".

stuck_checks_source(Target) ->
    "-ifdef(TEST).\n"
    "-include_lib(\"eunit/include/eunit.hrl\").\n"
    "add_test() ->\n"
    "    register(mutate_test_stuck_test_process, self()),\n"
    "    spawn(fun() -> register(mutate_test_stuck_helper, self()), timer:sleep(infinity) end),\n"
    "    case " ++ atom_to_list(Target) ++
        ":add(2, 3) of\n"
        "        5 -> ok;\n"
        "        _ -> timer:sleep(infinity)\n"
        "    end.\n"
        "-endif.\n".

helper_source(Ending) ->
    "-ifdef(TEST).\n"
    "-include_lib(\"eunit/include/eunit.hrl\").\n"
    "helper_test_() ->\n"
    "    {timeout, 1, fun() ->\n"
    "        Parent = self(),\n"
    "        spawn(fun() ->\n"
    "            register(mutate_test_helper, self()),\n"
    "            Parent ! registered,\n"
    "            receive stop -> ok end\n"
    "        end),\n"
    "        receive registered -> ok end,\n"
    "        end_with(" ++ atom_to_list(Ending) ++
        ")\n"
        "    end}.\n"
        "end_with(passing) -> ok;\n"
        "end_with(blocking) -> receive never -> ok end.\n"
        "-endif.\n".

writer_source() ->
    "-ifdef(TEST).\n"
    "-include_lib(\"eunit/include/eunit.hrl\").\n"
    "-export([write/1]).\n"
    "write_test_() -> {timeout, 60, fun() -> write(0) end}.\n"
    "write(N) ->\n"
    "    ets:insert(mutate_test_side_effects, {writes, N}),\n"
    "    timer:sleep(20),\n"
    "    write(N + 1).\n"
    "-endif.\n".

%% Passes only if nothing else writes the shared table while it runs.
steady_checks_source() ->
    "-ifdef(TEST).\n"
    "-include_lib(\"eunit/include/eunit.hrl\").\n"
    "steady_test() ->\n"
    "    Before = ets:lookup(mutate_test_side_effects, writes),\n"
    "    timer:sleep(200),\n"
    "    ?assertEqual(Before, ets:lookup(mutate_test_side_effects, writes)).\n"
    "-endif.\n".

side_app_source() ->
    "-behaviour(application).\n"
    "-export([start/2, stop/1]).\n"
    "start(_Type, _Args) -> {ok, spawn_link(fun() -> write(0) end)}.\n"
    "stop(_State) -> ok.\n"
    "write(N) ->\n"
    "    ets:insert(mutate_test_side_effects, {writes, N}),\n"
    "    timer:sleep(20),\n"
    "    write(N + 1).\n".

hanging_app_source(Child) ->
    "-behaviour(application).\n"
    "-behaviour(supervisor).\n"
    "-export([start/2, stop/1, init/1]).\n"
    "start(_Type, _Args) -> supervisor:start_link({local, mutate_test_hang_sup}, ?MODULE, []).\n"
    "stop(_State) -> ok.\n"
    "init([]) ->\n"
    "    Child = #{id => child, start => {" ++ atom_to_list(Child) ++
        ", start_link, []}, shutdown => infinity},\n"
        "    {ok, {#{}, [Child]}}.\n".

hanging_child_source() ->
    "-behaviour(gen_server).\n"
    "-export([start_link/0, init/1, handle_call/3, handle_cast/2, terminate/2]).\n"
    "start_link() -> gen_server:start_link({local, mutate_test_hang_child}, ?MODULE, [], []).\n"
    "init([]) -> process_flag(trap_exit, true), {ok, []}.\n"
    "handle_call(_Request, _From, State) -> {reply, ok, State}.\n"
    "handle_cast(_Request, State) -> {noreply, State}.\n"
    "terminate(_Reason, _State) -> receive never -> ok end.\n".

app_start_checks_source(App) ->
    "-ifdef(TEST).\n"
    "-include_lib(\"eunit/include/eunit.hrl\").\n"
    "started_test() -> ?assertEqual(ok, application:start(" ++ atom_to_list(App) ++
        ")).\n"
        "-endif.\n".

app_stopper_source(App) ->
    "-ifdef(TEST).\n"
    "-include_lib(\"eunit/include/eunit.hrl\").\n"
    "stop_test_() -> {timeout, 60, fun() -> application:stop(" ++ atom_to_list(App) ++
        ") end}.\n"
        "-endif.\n".

app_starter_source(App) ->
    "-ifdef(TEST).\n"
    "-include_lib(\"eunit/include/eunit.hrl\").\n"
    "started_test_() ->\n"
    "    {setup,\n"
    "        fun() -> ok = application:start(" ++ atom_to_list(App) ++
        ") end,\n"
        "        fun(_) -> application:stop(" ++ atom_to_list(App) ++
        ") end,\n"
        "        {timeout, 60, fun() -> timer:sleep(infinity) end}}.\n"
        "-endif.\n".

unrelated_checks_source() ->
    "-ifdef(TEST).\n"
    "-include_lib(\"eunit/include/eunit.hrl\").\n"
    "trivial_test() -> ?assert(true).\n"
    "-endif.\n".

build(Module, Body) ->
    Dir = tmp_dir(),
    File = filename:join(Dir, atom_to_list(Module) ++ ".erl"),
    Source = "-module(" ++ atom_to_list(Module) ++ ").\n" ++ Body,
    ok = file:write_file(File, Source),
    {ok, Module} = compile:file(File, [{outdir, Dir}, debug_info, {d, 'TEST'}]),
    code:purge(Module),
    {module, Module} = code:load_file(Module),
    {ok, Module, Forms} = rebar3_mutate_ast:parse_file(File, rebar3_mutate_opts:epp([], [])),
    {Module, Forms, File}.

load_test_application(App, Modules) ->
    application:load(
        {application, App, [
            {description, "rebar3_mutate test application"},
            {vsn, "1"},
            {modules, Modules},
            {registered, []},
            {applications, [kernel, stdlib]},
            {mod, {App, []}}
        ]}
    ).

kill_registered(Names) ->
    _ = [
        begin
            MRef = erlang:monitor(process, Pid),
            exit(Pid, kill),
            receive
                {'DOWN', MRef, process, Pid, _} -> ok
            end
        end
     || Name <- Names, Pid <- [whereis(Name)], is_pid(Pid)
    ],
    ok.

await_stopped(App) ->
    case lists:keymember(App, 1, application:which_applications()) of
        true ->
            timer:sleep(10),
            await_stopped(App);
        false ->
            ok
    end.

cleanup(Module, File) ->
    code:purge(Module),
    code:delete(Module),
    file:delete(File),
    file:delete(filename:rootname(File) ++ ".beam").
