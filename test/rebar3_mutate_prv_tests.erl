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
    ?assertNotEqual(nomatch, string:find(lists:flatten(Message), "no mutant could be tested")).

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

counts(Killed, Survived) ->
    #{
        killed => Killed,
        survived => Survived,
        timed_out => 0,
        compile_errors => 0,
        skipped => 0,
        total => Killed + Survived
    }.
