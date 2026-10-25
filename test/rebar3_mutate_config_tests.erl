-module(rebar3_mutate_config_tests).

-include_lib("eunit/include/eunit.hrl").

no_config_means_no_mapping_test() ->
    ?assertEqual({ok, #{eunit_tests => #{}}}, rebar3_mutate_config:parse([])).

eunit_tests_mapping_is_accepted_test() ->
    Mapping = #{
        rebar3_mutate_pool => [rebar3_mutate_report_tests],
        rebar3_mutate_report => [rebar3_mutate_diff_tests, rebar3_mutate_prv_tests]
    },
    ?assertEqual(
        {ok, #{eunit_tests => Mapping}},
        rebar3_mutate_config:parse([{eunit_tests, Mapping}])
    ).

%% The point of the option is that a green run means the listed tests ran, so
%% every mistake below has to stop the run rather than be skipped.
unknown_option_is_rejected_test() ->
    assert_error("Unknown mutate option eunit_test; known options: eunit_tests", [
        {eunit_test, #{}}
    ]).

non_list_config_is_rejected_test() ->
    assert_error("must be a list", #{eunit_tests => #{}}).

non_tuple_option_is_rejected_test() ->
    assert_error("must be {Key, Value} tuples", [eunit_tests]).

repeated_option_is_rejected_test() ->
    assert_error("set more than once", [{eunit_tests, #{}}, {eunit_tests, #{}}]).

non_map_eunit_tests_is_rejected_test() ->
    assert_error("must be a map", [
        {eunit_tests, [{rebar3_mutate_pool, [rebar3_mutate_report_tests]}]}
    ]).

non_atom_source_module_is_rejected_test() ->
    assert_error("keys must be module names", [
        {eunit_tests, #{"rebar3_mutate_pool" => [rebar3_mutate_report_tests]}}
    ]).

missing_source_module_is_rejected_test() ->
    assert_error("source module no_such_module was not found", [
        {eunit_tests, #{no_such_module => [rebar3_mutate_report_tests]}}
    ]).

non_atom_test_module_is_rejected_test() ->
    assert_error("must be atoms", [
        {eunit_tests, #{rebar3_mutate_pool => [~"rebar3_mutate_report_tests"]}}
    ]).

missing_test_module_is_rejected_test() ->
    assert_error("test module no_such_tests listed for rebar3_mutate_pool was not found", [
        {eunit_tests, #{rebar3_mutate_pool => [rebar3_mutate_report_tests, no_such_tests]}}
    ]).

%% A beam with no test functions would give a green baseline that ran nothing.
test_module_without_tests_is_rejected_test() ->
    assert_error("lists listed for rebar3_mutate_pool has no eunit tests", [
        {eunit_tests, #{rebar3_mutate_pool => [lists]}}
    ]).

%% rebar3_mutate_pool has no test functions of its own, but eunit:test/2 runs
%% rebar3_mutate_pool_tests for it.
test_module_counts_through_its_tests_module_test() ->
    Mapping = #{rebar3_mutate_report => [rebar3_mutate_pool]},
    ?assertEqual(
        {ok, #{eunit_tests => Mapping}}, rebar3_mutate_config:parse([{eunit_tests, Mapping}])
    ).

repeated_test_module_is_rejected_test() ->
    assert_error("rebar3_mutate_pool lists rebar3_mutate_report_tests more than once", [
        {eunit_tests, #{
            rebar3_mutate_pool => [rebar3_mutate_report_tests, rebar3_mutate_report_tests]
        }}
    ]).

%% eunit:test/2 already runs these, so the runner would drop them while the
%% log claimed they were counted.
own_tests_module_is_rejected_test() ->
    assert_error("rebar3_mutate_pool lists rebar3_mutate_pool_tests, which eunit already runs", [
        {eunit_tests, #{
            rebar3_mutate_pool => [rebar3_mutate_report_tests, rebar3_mutate_pool_tests]
        }}
    ]).

own_module_is_rejected_test() ->
    assert_error("rebar3_mutate_report lists rebar3_mutate_report, which eunit already runs", [
        {eunit_tests, #{rebar3_mutate_report => [rebar3_mutate_report]}}
    ]).

module_and_its_tests_module_together_are_rejected_test() ->
    assert_error(
        "rebar3_mutate_report lists both rebar3_mutate_pool and rebar3_mutate_pool_tests", [
            {eunit_tests, #{
                rebar3_mutate_report => [rebar3_mutate_pool_tests, rebar3_mutate_pool]
            }}
        ]
    ).

empty_test_list_is_rejected_test() ->
    assert_error("non-empty list", [{eunit_tests, #{rebar3_mutate_pool => []}}]),
    assert_error("non-empty list", [
        {eunit_tests, #{rebar3_mutate_pool => rebar3_mutate_report_tests}}
    ]).

assert_error(Expected, Config) ->
    {error, Message} = rebar3_mutate_config:parse(Config),
    ?assertNotEqual(nomatch, string:find(Message, Expected)).
