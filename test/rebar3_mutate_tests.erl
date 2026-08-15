-module(rebar3_mutate_tests).

-include_lib("eunit/include/eunit.hrl").

%% Mutating the plugin with the plugin swaps out code the run is executing:
%% loading the mutant makes the provider's code the old version, and restoring
%% the original must purge that old version, which kills the provider.
own_module_recognises_the_plugins_own_modules_test() ->
    ?assert(rebar3_mutate:own_module(rebar3_mutate_runner)),
    ?assert(rebar3_mutate:own_module(rebar3_mutate_prv)),
    ?assert(rebar3_mutate:own_module(rebar3_mutate_ast)),
    ?assert(rebar3_mutate:own_module(rebar3_mutate)).

own_module_is_false_for_anything_else_test() ->
    ?assertNot(rebar3_mutate:own_module(lists)),
    ?assertNot(rebar3_mutate:own_module(some_users_module)),
    ?assertNot(rebar3_mutate:own_module(rebar3_mutate_not_a_real_module)).

%% The whole point of the guard: purging a module a live process is running
%% kills that process, and during self-mutation that process is the provider.
purging_a_module_in_use_kills_the_process_test() ->
    Forms = [
        {attribute, 1, module, mutate_purge_victim},
        {attribute, 2, export, [{loop, 0}]},
        {function, 3, loop, 0, [
            {clause, 3, [], [], [
                {'receive', 3, [{clause, 3, [{atom, 3, stop}], [], [{atom, 3, ok}]}],
                    {integer, 3, 50}, [{call, 3, {atom, 3, loop}, []}]}
            ]}
        ]},
        {eof, 4}
    ],
    {ok, Binary} = rebar3_mutate_runner:compile_mutant(mutate_purge_victim, Forms),
    {module, _} = code:load_binary(mutate_purge_victim, "original", Binary),
    Pid = spawn(mutate_purge_victim, loop, []),
    timer:sleep(50),
    ?assert(is_process_alive(Pid)),
    {module, _} = code:load_binary(mutate_purge_victim, "mutant", Binary),
    ?assertNot(code:soft_purge(mutate_purge_victim)),
    ?assert(code:purge(mutate_purge_victim)),
    timer:sleep(50),
    ?assertNot(is_process_alive(Pid)),
    code:purge(mutate_purge_victim),
    code:delete(mutate_purge_victim).
