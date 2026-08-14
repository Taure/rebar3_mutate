-module(rebar3_mutate_pool).

-export([pmap/3]).

%% Bounded worker pool preserving input order.
%%
%% Two properties the previous chunked implementation did not have. Workers are
%% refilled as slots free rather than in fixed groups, so one slow task does not
%% stall the whole batch. And every task gets a result: a worker that dies
%% without sending one is reported through OnCrash instead of being dropped,
%% which previously removed the task from both the numerator and the
%% denominator of the score.
-spec pmap(fun((Task) -> Result), [Task], pos_integer()) -> [Result | Crash] when
    Task :: term(),
    Result :: term(),
    Crash :: term().
pmap(Fun, Tasks, MaxWorkers) ->
    pmap(Fun, Tasks, MaxWorkers, fun(Reason) -> {worker_crash, Reason} end).

-spec pmap(fun((Task) -> Result), [Task], pos_integer(), fun((term()) -> Crash)) ->
    [Result | Crash]
when
    Task :: term(), Result :: term(), Crash :: term().
pmap(_Fun, [], _MaxWorkers, _OnCrash) ->
    [];
pmap(Fun, Tasks, MaxWorkers, OnCrash) ->
    Indexed = lists:enumerate(Tasks),
    Results = drain(Fun, Indexed, max(MaxWorkers, 1), #{}, #{}, make_ref(), OnCrash),
    [maps:get(Index, Results) || {Index, _Task} <- Indexed].

drain(_Fun, [], _Max, InFlight, Results, _Ref, _OnCrash) when map_size(InFlight) =:= 0 ->
    Results;
drain(Fun, [{Index, Task} | Rest], Max, InFlight, Results, Ref, OnCrash) when
    map_size(InFlight) < Max
->
    Parent = self(),
    {_Pid, MRef} = spawn_monitor(fun() -> Parent ! {Ref, Index, Fun(Task)} end),
    drain(Fun, Rest, Max, InFlight#{MRef => Index}, Results, Ref, OnCrash);
drain(Fun, Pending, Max, InFlight, Results, Ref, OnCrash) ->
    receive
        {Ref, Index, Value} ->
            drain(Fun, Pending, Max, InFlight, Results#{Index => Value}, Ref, OnCrash);
        {'DOWN', MRef, process, _Pid, Reason} ->
            Index = maps:get(MRef, InFlight),
            drain(
                Fun,
                Pending,
                Max,
                maps:remove(MRef, InFlight),
                record_crash(Index, Reason, Results, OnCrash),
                Ref,
                OnCrash
            )
    end.

%% The worker sends its result before it exits and signals between a pair of
%% processes keep their order, so a result already recorded here means the
%% task succeeded and this DOWN is just the normal exit that follows it.
record_crash(Index, _Reason, Results, _OnCrash) when is_map_key(Index, Results) ->
    Results;
record_crash(Index, Reason, Results, OnCrash) ->
    Results#{Index => OnCrash(Reason)}.
