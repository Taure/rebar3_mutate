-module(rebar3_mutate_runner).

-export([compile_mutant/2, run_mutant/4, load_and_test/4, run_baseline/3, has_tests/2]).

-type test_spec() :: eunit | {ct, atom()}.
-type verdict() :: killed | survived | timed_out | {compile_error, term()} | {skipped, term()}.

-export_type([test_spec/0, verdict/0]).

-spec compile_mutant(atom(), [erl_parse:abstract_form()]) ->
    {ok, binary()} | {compile_error, term()}.
compile_mutant(Module, MutatedForms) ->
    case compile:forms(MutatedForms, [binary, return_errors]) of
        {ok, Module, Binary} ->
            {ok, Binary};
        {ok, Module, Binary, _Warnings} ->
            {ok, Binary};
        {error, Errors, _Warnings} ->
            {compile_error, Errors}
    end.

-spec run_mutant(atom(), [erl_parse:abstract_form()], test_spec(), pos_integer()) -> verdict().
run_mutant(Module, MutatedForms, TestSpec, Timeout) ->
    case compile_mutant(Module, MutatedForms) of
        {ok, Binary} ->
            load_and_test(Module, Binary, TestSpec, Timeout);
        {compile_error, _} = Err ->
            Err
    end.

-spec load_and_test(atom(), binary(), test_spec(), pos_integer()) -> verdict().
load_and_test(Module, Binary, TestSpec, Timeout) ->
    case save_module(Module) of
        {error, Reason} ->
            {skipped, {no_original_code, Reason}};
        Saved ->
            try
                case load_mutant(Module, Binary) of
                    ok ->
                        case execute(TestSpec, Module, Timeout) of
                            pass -> survived;
                            fail -> killed;
                            timeout -> timed_out;
                            {error, Reason} -> {skipped, Reason}
                        end;
                    {error, Reason} ->
                        {skipped, {load_failed, Reason}}
                end
            after
                restore_module(Module, Saved)
            end
    end.

%% A mutation score is only meaningful if the suite passes unmutated. Without
%% this, one pre-existing failing test makes every mutant read as killed and
%% the run reports 100%.
-spec run_baseline(atom(), test_spec(), pos_integer()) ->
    {ok, non_neg_integer()} | no_tests | {failed, term()}.
run_baseline(Module, TestSpec, Timeout) ->
    case has_tests(Module, TestSpec) of
        false ->
            no_tests;
        true ->
            Start = erlang:monotonic_time(millisecond),
            case execute(TestSpec, Module, Timeout) of
                pass -> {ok, erlang:monotonic_time(millisecond) - Start};
                fail -> {failed, tests_failing};
                timeout -> {failed, {timeout, Timeout}};
                {error, Reason} -> {failed, Reason}
            end
    end.

%% eunit:test/2 returns ok for a module with no tests at all, so a green
%% baseline does not by itself mean anything ran.
-spec has_tests(atom(), test_spec()) -> boolean().
has_tests(Module, eunit) ->
    Tests = atom_to_list(Module) ++ "_tests.beam",
    case code:where_is_file(Tests) of
        non_existing -> exports_test_function(Module);
        _Path -> true
    end;
has_tests(_Module, {ct, Suite}) ->
    case code:ensure_loaded(Suite) of
        {module, Suite} -> true;
        {error, _} -> false
    end.

%%====================================================================
%% Test execution
%%====================================================================

execute(eunit, Module, Timeout) ->
    in_worker(
        fun() ->
            try eunit:test(Module, [no_tty]) of
                ok -> pass;
                error -> fail
            catch
                _:_ -> fail
            end
        end,
        Timeout
    );
execute({ct, Suite}, _Module, Timeout) ->
    in_worker(
        fun() ->
            try ct:run_test([{suite, Suite}, {logopts, [no_src]}, {verbosity, 0}]) of
                {_Ok, 0, {0, 0}} -> pass;
                {error, Reason} -> {error, {ct_failed, Reason}};
                _ -> fail
            catch
                _:_ -> fail
            end
        end,
        Timeout
    );
execute(Other, _Module, _Timeout) ->
    {error, {unknown_test_framework, Other}}.

%% The worker sends before it exits, and signals between two processes keep
%% their order, so the result is always ahead of the DOWN in the mailbox.
in_worker(Fun, Timeout) ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, MRef} = spawn_monitor(fun() -> Parent ! {Ref, Fun()} end),
    receive
        {Ref, Result} ->
            erlang:demonitor(MRef, [flush]),
            Result;
        {'DOWN', MRef, process, Pid, _Reason} ->
            fail
    after Timeout ->
        erlang:demonitor(MRef, [flush]),
        exit(Pid, kill),
        timeout
    end.

%%====================================================================
%% Code loading
%%====================================================================

%% Only an on-disk beam is a restorable original. code:which/1 also answers
%% with cover_compiled, preloaded, non_existing, or whatever filename a module
%% loaded from a binary was tagged with, and restoring from any of those either
%% silently does nothing or fails after the mutant is already resident.
save_module(Module) ->
    case code:get_object_code(Module) of
        {Module, Binary, Filename} ->
            {object_code, Binary, Filename};
        error ->
            case code:which(Module) of
                Path when is_list(Path) ->
                    case filename:extension(Path) =:= ".beam" andalso filelib:is_regular(Path) of
                        true -> {beam_path, Path};
                        false -> {error, {not_restorable, Path}}
                    end;
                Other ->
                    {error, {not_restorable, Other}}
            end
    end.

load_mutant(Module, Binary) ->
    purge(Module),
    case code:load_binary(Module, "mutant", Binary) of
        {module, Module} -> ok;
        {error, Reason} -> {error, Reason}
    end.

%% Restoration has to be total: leaving a mutant resident poisons every later
%% mutant and every later module in the same run, so a failure here is fatal
%% rather than something to warn about and continue past.
restore_module(Module, {object_code, Binary, Filename}) ->
    purge(Module),
    case code:load_binary(Module, Filename, Binary) of
        {module, Module} -> ok;
        {error, Reason} -> erlang:error({mutant_restore_failed, Module, Reason})
    end;
restore_module(Module, {beam_path, _Path}) ->
    purge(Module),
    case code:load_file(Module) of
        {module, Module} -> ok;
        {error, Reason} -> erlang:error({mutant_restore_failed, Module, Reason})
    end.

purge(Module) ->
    case code:soft_purge(Module) of
        true ->
            ok;
        false ->
            _ = code:purge(Module),
            ok
    end.

exports_test_function(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            lists:any(
                fun
                    ({Name, 0}) -> is_test_name(atom_to_list(Name));
                    ({_, _}) -> false
                end,
                Module:module_info(exports)
            );
        {error, _} ->
            false
    end.

is_test_name(Name) ->
    lists:suffix("_test", Name) orelse lists:suffix("_test_", Name).
