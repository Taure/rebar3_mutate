-module(rebar3_mutate_pool_tests).

-include_lib("eunit/include/eunit.hrl").

empty_task_list_test() ->
    ?assertEqual([], rebar3_mutate_pool:pmap(fun(X) -> X end, [], 4)).

preserves_input_order_test() ->
    Tasks = lists:seq(1, 50),
    Result = rebar3_mutate_pool:pmap(fun(N) -> N * 2 end, Tasks, 8),
    ?assertEqual([N * 2 || N <- Tasks], Result).

%% Completion order is deliberately the reverse of submission order here, so an
%% implementation that returned results as they arrive would fail this.
out_of_order_completion_still_returns_in_order_test() ->
    Tasks = lists:seq(1, 10),
    Result = rebar3_mutate_pool:pmap(
        fun(N) ->
            timer:sleep((11 - N) * 5),
            N
        end,
        Tasks,
        10
    ),
    ?assertEqual(Tasks, Result).

respects_the_worker_limit_test() ->
    Counter = counters:new(1, []),
    Peak = counters:new(1, []),
    Track = fun(_Task) ->
        counters:add(Counter, 1, 1),
        Live = counters:get(Counter, 1),
        case Live > counters:get(Peak, 1) of
            true -> counters:put(Peak, 1, Live);
            false -> ok
        end,
        timer:sleep(20),
        counters:sub(Counter, 1, 1),
        ok
    end,
    _ = rebar3_mutate_pool:pmap(Track, lists:seq(1, 20), 3),
    ?assert(counters:get(Peak, 1) =< 3).

%% A worker that dies used to be dropped from the results entirely, so its
%% mutant vanished from both the numerator and the denominator of the score.
crashed_worker_yields_a_result_not_a_gap_test() ->
    Result = rebar3_mutate_pool:pmap(
        fun
            (2) -> error(boom);
            (N) -> N
        end,
        [1, 2, 3],
        4
    ),
    ?assertMatch([1, {worker_crash, _}, 3], Result).

every_worker_crashing_still_returns_one_result_each_test() ->
    Result = rebar3_mutate_pool:pmap(fun(_) -> exit(nope) end, lists:seq(1, 12), 4),
    ?assertEqual(12, length(Result)),
    ?assertEqual([], [R || R <- Result, R =/= {worker_crash, nope}]).

single_worker_crash_matches_parallel_behaviour_test() ->
    Crashing = fun
        (2) -> error(boom);
        (N) -> N
    end,
    Serial = rebar3_mutate_pool:pmap(Crashing, [1, 2, 3], 1),
    Parallel = rebar3_mutate_pool:pmap(Crashing, [1, 2, 3], 8),
    ?assertMatch([1, {worker_crash, _}, 3], Serial),
    ?assertEqual(length(Serial), length(Parallel)).

more_workers_than_tasks_test() ->
    ?assertEqual([1, 2], rebar3_mutate_pool:pmap(fun(N) -> N end, [1, 2], 64)).
