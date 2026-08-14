-module(rebar3_mutate_opts_tests).

-include_lib("eunit/include/eunit.hrl").

epp_always_defines_test_test() ->
    Epp = rebar3_mutate_opts:epp([], []),
    ?assertEqual([{'TEST', true}], proplists:get_value(macros, Epp)).

epp_carries_project_defines_test() ->
    Epp = rebar3_mutate_opts:epp([debug_info, {d, 'FEATURE_X'}, {d, 'LIMIT', 42}], []),
    Macros = proplists:get_value(macros, Epp),
    ?assert(lists:member({'FEATURE_X', true}, Macros)),
    ?assert(lists:member({'LIMIT', 42}, Macros)),
    ?assert(lists:member({'TEST', true}, Macros)).

epp_merges_include_dirs_test() ->
    Epp = rebar3_mutate_opts:epp([{i, "extra/include"}], ["app/include"]),
    ?assertEqual(["app/include", "extra/include"], proplists:get_value(includes, Epp)).

epp_enables_requested_features_test() ->
    Epp = rebar3_mutate_opts:epp([{feature, maybe_expr, enable}], []),
    ?assertEqual([maybe_expr], proplists:get_value(features, Epp)),
    ?assertEqual(undefined, proplists:get_value(features, rebar3_mutate_opts:epp([], []))).

%% Defines and include paths are spent by the time epp hands over forms, so
%% forwarding them again is noise; parse transforms and features still apply.
compile_forwards_only_what_still_applies_test() ->
    Compile = rebar3_mutate_opts:compile([
        debug_info,
        {d, 'FEATURE_X'},
        {i, "include"},
        {parse_transform, my_transform},
        {feature, maybe_expr, enable},
        nowarn_unused_vars,
        {outdir, "ebin"}
    ]),
    ?assert(lists:member(binary, Compile)),
    ?assert(lists:member(return_errors, Compile)),
    ?assert(lists:member({parse_transform, my_transform}, Compile)),
    ?assert(lists:member({feature, maybe_expr, enable}, Compile)),
    ?assert(lists:member(nowarn_unused_vars, Compile)),
    ?assertNot(lists:member(debug_info, Compile)),
    ?assertNot(lists:member({outdir, "ebin"}, Compile)).

%% A mutant routinely leaves a variable unused. Promoting that to an error would
%% quietly move mutants out of the denominator instead of testing them.
compile_never_forwards_warnings_as_errors_test() ->
    Compile = rebar3_mutate_opts:compile([warnings_as_errors, debug_info]),
    ?assertNot(lists:member(warnings_as_errors, Compile)).

%% rebar3 runs this provider in the test profile, whose erl_opts already define
%% TEST. epp rejects a macro defined twice, so prepending it unconditionally
%% made every module fail to parse with {redefine, 'TEST'}.
epp_does_not_redefine_test_macro_test() ->
    Epp = rebar3_mutate_opts:epp([{d, 'TEST'}], []),
    Macros = proplists:get_value(macros, Epp),
    ?assertEqual(1, length([K || {K, _} <- Macros, K =:= 'TEST'])).

epp_deduplicates_repeated_defines_test() ->
    Epp = rebar3_mutate_opts:epp([{d, 'A', 1}, {d, 'B'}, {d, 'A', 2}], []),
    Macros = proplists:get_value(macros, Epp),
    ?assertEqual(1, length([K || {K, _} <- Macros, K =:= 'A'])),
    ?assert(lists:member({'A', 1}, Macros)),
    ?assert(lists:member({'B', true}, Macros)).
