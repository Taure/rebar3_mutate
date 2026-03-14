-module(rebar3_mutate_runner).

-export([run_mutant/4]).

-spec run_mutant(atom(), [erl_parse:abstract_form()], eunit | {ct, atom()}, pos_integer()) ->
    killed | survived | timed_out | {compile_error, term()}.
run_mutant(Module, MutatedForms, TestSpec, Timeout) ->
    case compile:forms(MutatedForms, [binary, return_errors]) of
        {ok, Module, Binary} ->
            load_and_test(Module, Binary, TestSpec, Timeout);
        {ok, Module, Binary, _Warnings} ->
            load_and_test(Module, Binary, TestSpec, Timeout);
        {error, Errors, _Warnings} ->
            {compile_error, Errors}
    end.

%%====================================================================
%% Internal
%%====================================================================

load_and_test(Module, Binary, TestSpec, Timeout) ->
    %% Save original beam path for restore
    OldPath = code:which(Module),
    %% Hot-load the mutant
    {module, Module} = code:load_binary(Module, "mutant", Binary),
    Result = run_tests(TestSpec, Module, Timeout),
    %% Restore original
    restore_module(Module, OldPath),
    Result.

run_tests(eunit, Module, Timeout) ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, MRef} = spawn_monitor(fun() ->
        try eunit:test(Module, [no_tty]) of
            ok -> Parent ! {Ref, survived};
            error -> Parent ! {Ref, killed}
        catch
            _:_ -> Parent ! {Ref, killed}
        end
    end),
    receive
        {Ref, Result} ->
            erlang:demonitor(MRef, [flush]),
            Result;
        {'DOWN', MRef, process, Pid, normal} ->
            %% Process exited without sending result — treat as killed
            killed;
        {'DOWN', MRef, process, Pid, _Reason} ->
            killed
    after Timeout ->
        erlang:demonitor(MRef, [flush]),
        exit(Pid, kill),
        timed_out
    end;
run_tests({ct, Suite}, _Module, Timeout) ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, MRef} = spawn_monitor(fun() ->
        try ct:run_test([{suite, Suite}, {logopts, [no_src]}, {verbosity, 0}]) of
            {_Ok, 0, {0, 0}} -> Parent ! {Ref, survived};
            _ -> Parent ! {Ref, killed}
        catch
            _:_ -> Parent ! {Ref, killed}
        end
    end),
    receive
        {Ref, Result} ->
            erlang:demonitor(MRef, [flush]),
            Result;
        {'DOWN', MRef, process, Pid, normal} ->
            killed;
        {'DOWN', MRef, process, Pid, _Reason} ->
            killed
    after Timeout ->
        erlang:demonitor(MRef, [flush]),
        exit(Pid, kill),
        timed_out
    end.

restore_module(Module, OldPath) when is_list(OldPath) ->
    code:load_file(Module);
restore_module(_Module, _) ->
    ok.
