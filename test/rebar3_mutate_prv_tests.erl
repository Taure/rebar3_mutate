-module(rebar3_mutate_prv_tests).

-include_lib("eunit/include/eunit.hrl").

no_threshold_always_passes_test() ->
    ?assertEqual(pass, rebar3_mutate_prv:gate_decision(counts(0, 0), undefined, none)),
    ?assertEqual(pass, rebar3_mutate_prv:gate_decision(counts(1, 9), undefined, none)).

score_at_or_above_the_threshold_passes_test() ->
    ?assertEqual(pass, rebar3_mutate_prv:gate_decision(counts(9, 1), 90.0, none)),
    ?assertEqual(pass, rebar3_mutate_prv:gate_decision(counts(10, 0), 90.0, none)).

score_below_the_threshold_fails_test() ->
    ?assertMatch({fail, _}, rebar3_mutate_prv:gate_decision(counts(8, 2), 90.0, none)).

%% Every module skipped for want of tests used to satisfy any threshold: the
%% run measured nothing and reported success, which is the one outcome a CI
%% gate must never produce.
nothing_measured_fails_the_gate_test() ->
    ?assertMatch({fail, _}, rebar3_mutate_prv:gate_decision(counts(0, 0), 90.0, none)),
    {fail, Message} = rebar3_mutate_prv:gate_decision(counts(0, 0), 90.0, none),
    ?assertNotEqual(
        nomatch, binary:match(iolist_to_binary(Message), ~"no mutant could be tested")
    ).

%% An empty diff is different: the change genuinely touched no mutable line, so
%% there is nothing to gate and passing is correct.
nothing_measured_in_diff_mode_passes_test() ->
    ?assertMatch({pass, _}, rebar3_mutate_prv:gate_decision(counts(0, 0), 90.0, {diff, #{}})).

%% Compile errors and skips are outside the denominator, so a run whose only
%% mutants were untestable has still measured nothing.
only_untestable_mutants_fails_the_gate_test() ->
    Counts = #{
        killed => 0,
        survived => 0,
        timed_out => 0,
        compile_errors => 12,
        skipped => 3,
        total => 15
    },
    ?assertEqual(0, rebar3_mutate_report:testable(Counts)),
    ?assertMatch({fail, _}, rebar3_mutate_prv:gate_decision(Counts, 80.0, none)).

%%====================================================================
%% Config
%%====================================================================

invalid_config_stops_the_run_test() ->
    State0 = rebar_state:set(rebar_state:new(), mutate, [{eunit_test, #{}}]),
    State = rebar_state:command_parsed_args(State0, {[], []}),
    ?assertMatch(
        {error, {rebar3_mutate_prv, "Unknown mutate option eunit_test" ++ _}},
        rebar3_mutate_prv:do(State)
    ).

eunit_mapping_is_reported_as_ignored_under_ct_test() ->
    Mapping = #{my_module => [integration_tests]},
    ?assert(rebar3_mutate_prv:mapping_ignored(#{framework => ct, eunit_tests => Mapping})),
    ?assertNot(rebar3_mutate_prv:mapping_ignored(#{framework => ct, eunit_tests => #{}})),
    ?assertNot(rebar3_mutate_prv:mapping_ignored(#{framework => eunit, eunit_tests => Mapping})).

%%====================================================================
%% Test spec resolution
%%====================================================================

unmapped_module_keeps_plain_eunit_test() ->
    Opts = #{framework => eunit, eunit_tests => #{other_module => [other_module_checks]}},
    ?assertEqual({ok, eunit}, rebar3_mutate_prv:resolve_test_spec(my_module, Opts)).

mapped_module_gets_its_extra_test_modules_test() ->
    Opts = #{framework => eunit, eunit_tests => #{my_module => [integration_tests, sandbox_tests]}},
    ?assertEqual(
        {ok, {eunit, [integration_tests, sandbox_tests]}},
        rebar3_mutate_prv:resolve_test_spec(my_module, Opts)
    ).

eunit_mapping_does_not_apply_to_ct_test() ->
    Opts = #{
        framework => ct,
        suite => "my_SUITE",
        eunit_tests => #{my_module => [integration_tests]}
    },
    ?assertEqual({ok, {ct, my_SUITE}}, rebar3_mutate_prv:resolve_test_spec(my_module, Opts)).

%%====================================================================
%% Baseline repeatability
%%====================================================================

baseline_timeout_has_a_floor_test() ->
    ?assertEqual(30000, rebar3_mutate_prv:baseline_timeout(5000)),
    ?assertEqual(30000, rebar3_mutate_prv:baseline_timeout(7500)),
    ?assertEqual(40000, rebar3_mutate_prv:baseline_timeout(10000)).

baseline_repeatability_test_() ->
    {foreach, fun setup/0, fun teardown/1, [
        fun stateful_suite_fails_the_baseline_instead_of_killing/1,
        fun suite_broken_by_the_mutants_fails_the_baseline/1,
        fun repeatable_suite_is_scored/1,
        fun no_mutation_points_runs_no_baseline/1,
        fun timed_out_last_mutant_keeps_the_module_scored/1,
        fun mutant_stuck_in_test_code_does_not_reach_the_next_run/1,
        fun crashed_compile_worker_is_recorded_as_skipped/1
    ]}.

%% Any failing run counts as a kill. A suite that leaves state behind passes
%% the first baseline and then fails every later run, so a mutant identical to
%% the original reads as killed; the second baseline has to catch it first.
stateful_suite_fails_the_baseline_instead_of_killing(Dir) ->
    fun() ->
        {Module, Forms, File} = build(Dir, mutate_prv_stateful, target_source()),
        {Checks, _, _} = build(Dir, mutate_prv_stateful_checks, stateful_source(Module)),
        Spec = {eunit, [Checks]},
        ?assertMatch({ok, _Ms}, rebar3_mutate_runner:run_baseline(Module, Spec, 5000)),
        {ok, Identical} = rebar3_mutate_runner:compile_mutant(Module, Forms),
        ?assertEqual(killed, rebar3_mutate_runner:load_and_test(Module, Identical, Spec, 5000)),
        persistent_term:erase(mutate_prv_marker),
        ?assertMatch(
            {baseline_failed, Module, {not_repeatable, tests_failing}},
            rebar3_mutate_prv:baseline_then_mutate(Module, Forms, File, Spec, app_opts(), opts())
        )
    end.

suite_broken_by_the_mutants_fails_the_baseline(Dir) ->
    fun() ->
        {Module, Forms, File} = build(Dir, mutate_prv_decaying, target_source()),
        {Checks, _, _} = build(Dir, mutate_prv_decaying_checks, counting_source(Module, 2)),
        ?assertMatch(
            {baseline_failed, Module, {not_repeatable_after_mutants, tests_failing}},
            rebar3_mutate_prv:baseline_then_mutate(
                Module, Forms, File, {eunit, [Checks]}, app_opts(), opts()
            )
        )
    end.

repeatable_suite_is_scored(Dir) ->
    fun() ->
        {Module, Forms, File} = build(Dir, mutate_prv_repeatable, target_source()),
        {Checks, _, _} = build(Dir, mutate_prv_repeatable_checks, checks_source(Module)),
        ?assertMatch(
            {ok, Module, [{_Point, killed} | _]},
            rebar3_mutate_prv:baseline_then_mutate(
                Module, Forms, File, {eunit, [Checks]}, app_opts(), opts()
            )
        )
    end.

%% In diff mode most modules have no mutable line in the change; running their
%% suites three times would measure nothing.
no_mutation_points_runs_no_baseline(Dir) ->
    fun() ->
        {Module, Forms, File} = build(Dir, mutate_prv_pointless, target_source()),
        {Checks, _, _} = build(Dir, mutate_prv_pointless_checks, counting_source(Module, 99)),
        ?assertEqual(
            {ok, Module, []},
            rebar3_mutate_prv:baseline_then_mutate(
                Module, Forms, File, {eunit, [Checks]}, app_opts(), (opts())#{
                    operators => [op_list]
                }
            )
        ),
        ?assertEqual([{runs, 0}], ets:lookup(mutate_prv_runs, runs))
    end.

%% A timed-out mutant's eunit test process outlives the killed worker. Left
%% running, it still holds the name the suite registers, and the check after
%% the last mutant fails a suite that is in fact repeatable.
timed_out_last_mutant_keeps_the_module_scored(Dir) ->
    {timeout, 60, fun() ->
        {Module, Forms, File} = build(Dir, mutate_prv_looping, looping_source()),
        {Checks, _, _} = build(Dir, mutate_prv_looping_checks, registering_source(Module)),
        ?assertMatch(
            {ok, Module, [{_, timed_out}]},
            rebar3_mutate_prv:baseline_then_mutate(
                Module, Forms, File, {eunit, [Checks]}, app_opts(), (opts())#{timeout => 1000}
            )
        )
    end}.

mutant_stuck_in_test_code_does_not_reach_the_next_run(Dir) ->
    {timeout, 60, fun() ->
        {Module, Forms, File} = build(Dir, mutate_prv_stuck, target_source()),
        {Checks, _, _} = build(Dir, mutate_prv_stuck_checks, stuck_source(Module)),
        ?assertMatch(
            {ok, Module, [{_, timed_out}]},
            rebar3_mutate_prv:baseline_then_mutate(
                Module, Forms, File, {eunit, [Checks]}, app_opts(), (opts())#{timeout => 1000}
            )
        )
    end}.

crashed_compile_worker_is_recorded_as_skipped(Dir) ->
    fun() ->
        {Module, Forms, File} = build(Dir, mutate_prv_crashing, target_source()),
        {Checks, _, _} = build(Dir, mutate_prv_crashing_checks, checks_source(Module)),
        {Transform, _, _} = build(Dir, mutate_prv_renaming_transform, renaming_source()),
        AppOpts = #{compile => [binary, return_errors, {parse_transform, Transform}]},
        ?assertMatch(
            {ok, Module, [{_, {skipped, {worker_crash, _}}}]},
            rebar3_mutate_prv:baseline_then_mutate(
                Module, Forms, File, {eunit, [Checks]}, AppOpts, opts()
            )
        )
    end.

counts(Killed, Survived) ->
    #{
        killed => Killed,
        survived => Survived,
        timed_out => 0,
        compile_errors => 0,
        skipped => 0,
        total => Killed + Survived
    }.

opts() ->
    #{timeout => 5000, operators => [op_arithmetic], workers => 1, diff => none}.

app_opts() ->
    #{compile => [binary, return_errors]}.

target_source() ->
    "-export([add/2]).\n"
    "add(A, B) -> A + B.\n".

checks_source(Target) ->
    "-ifdef(TEST).\n"
    "-include_lib(\"eunit/include/eunit.hrl\").\n"
    "add_test() -> ?assertEqual(5, " ++ atom_to_list(Target) ++
        ":add(2, 3)).\n"
        "-endif.\n".

stateful_source(Target) ->
    "-ifdef(TEST).\n"
    "-include_lib(\"eunit/include/eunit.hrl\").\n"
    "add_test() ->\n"
    "    ?assertEqual(undefined, persistent_term:get(mutate_prv_marker, undefined)),\n"
    "    persistent_term:put(mutate_prv_marker, set),\n"
    "    ?assertEqual(5, " ++ atom_to_list(Target) ++
        ":add(2, 3)).\n"
        "-endif.\n".

counting_source(Target, PassingRuns) ->
    "-ifdef(TEST).\n"
    "-include_lib(\"eunit/include/eunit.hrl\").\n"
    "add_test() ->\n"
    "    ?assert(ets:update_counter(mutate_prv_runs, runs, 1) =< " ++
        integer_to_list(PassingRuns) ++
        "),\n"
        "    ?assertEqual(5, " ++ atom_to_list(Target) ++
        ":add(2, 3)).\n"
        "-endif.\n".

looping_source() ->
    "-export([count/1]).\n"
    "count(0) -> ok;\n"
    "count(N) when N > 0 -> count(N - 1).\n".

registering_source(Target) ->
    "-ifdef(TEST).\n"
    "-include_lib(\"eunit/include/eunit.hrl\").\n"
    "count_test() ->\n"
    "    register(mutate_prv_victim, self()),\n"
    "    ok = " ++ atom_to_list(Target) ++
        ":count(3),\n"
        "    unregister(mutate_prv_victim).\n"
        "-endif.\n".

stuck_source(Target) ->
    "-ifdef(TEST).\n"
    "-include_lib(\"eunit/include/eunit.hrl\").\n"
    "add_test() ->\n"
    "    register(mutate_prv_stuck_victim, self()),\n"
    "    case " ++ atom_to_list(Target) ++
        ":add(2, 3) of\n"
        "        5 -> ok;\n"
        "        _ -> timer:sleep(infinity)\n"
        "    end,\n"
        "    unregister(mutate_prv_stuck_victim).\n"
        "-endif.\n".

%% Renaming the module makes compile:forms/2 succeed for a module other than
%% the one asked for, which compile_mutant does not match, so its worker dies.
renaming_source() ->
    "-export([parse_transform/2]).\n"
    "parse_transform(Forms, _Options) ->\n"
    "    [rename(Form) || Form <- Forms].\n"
    "rename({attribute, Anno, module, _}) -> {attribute, Anno, module, mutate_prv_renamed};\n"
    "rename(Form) -> Form.\n".

setup() ->
    Dir = "/tmp/rebar3_mutate_prv_test_" ++ os:getpid(),
    ok = filelib:ensure_dir(Dir ++ "/dummy"),
    true = code:add_patha(Dir),
    ets:new(mutate_prv_runs, [named_table, public]),
    ets:insert(mutate_prv_runs, {runs, 0}),
    Dir.

teardown(Dir) ->
    Modules = [
        Module
     || {Module, Path} <- code:all_loaded(), is_list(Path), lists:prefix(Dir, Path)
    ],
    [
        begin
            code:purge(Module),
            code:delete(Module),
            code:purge(Module)
        end
     || Module <- Modules
    ],
    code:del_path(Dir),
    file:del_dir_r(Dir),
    ets:delete(mutate_prv_runs),
    persistent_term:erase(mutate_prv_marker),
    ok.

build(Dir, Module, Body) ->
    File = Dir ++ "/" ++ atom_to_list(Module) ++ ".erl",
    ok = file:write_file(File, "-module(" ++ atom_to_list(Module) ++ ").\n" ++ Body),
    {ok, Module} = compile:file(File, [{outdir, Dir}, debug_info, {d, 'TEST'}]),
    code:purge(Module),
    {module, Module} = code:load_file(Module),
    {ok, Module, Forms} = rebar3_mutate_ast:parse_file(File, rebar3_mutate_opts:epp([], [])),
    {Module, Forms, File}.
