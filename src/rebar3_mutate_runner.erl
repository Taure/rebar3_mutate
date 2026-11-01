-module(rebar3_mutate_runner).

-export([
    compile_mutant/2,
    compile_mutant/3,
    run_mutant/4,
    run_mutant/5,
    load_and_test/4,
    run_baseline/3,
    has_tests/2,
    contributes_tests/1
]).

-type test_spec() :: eunit | {eunit, [module()]} | {ct, atom()}.
-type verdict() :: killed | survived | timed_out | {compile_error, term()} | {skipped, term()}.

-export_type([test_spec/0, verdict/0]).

-spec compile_mutant(atom(), rebar3_mutate_ast:forms()) ->
    {ok, binary()} | {compile_error, term()}.
compile_mutant(Module, MutatedForms) ->
    compile_mutant(Module, MutatedForms, [binary, return_errors]).

-spec compile_mutant(atom(), rebar3_mutate_ast:forms(), [compile:option()]) ->
    {ok, binary()} | {compile_error, term()}.
compile_mutant(Module, MutatedForms, CompileOpts) ->
    case compile_forms(MutatedForms, CompileOpts) of
        {ok, Module, Binary} when is_binary(Binary) ->
            {ok, Binary};
        {ok, Module, Binary, _Warnings} when is_binary(Binary) ->
            {ok, Binary};
        {error, Errors, _Warnings} ->
            {compile_error, Errors}
    end.

-spec compile_forms(dynamic(), [compile:option()]) -> compile:comp_ret().
compile_forms(Forms, CompileOpts) ->
    compile:forms(Forms, CompileOpts).

-spec run_mutant(atom(), rebar3_mutate_ast:forms(), test_spec(), pos_integer()) -> verdict().
run_mutant(Module, MutatedForms, TestSpec, Timeout) ->
    run_mutant(Module, MutatedForms, TestSpec, Timeout, [binary, return_errors]).

-spec run_mutant(
    atom(), rebar3_mutate_ast:forms(), test_spec(), pos_integer(), [compile:option()]
) ->
    verdict().
run_mutant(Module, MutatedForms, TestSpec, Timeout, CompileOpts) ->
    case compile_mutant(Module, MutatedForms, CompileOpts) of
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
    case code:where_is_file(tests_name(Module) ++ ".beam") of
        non_existing -> exports_test_function(Module);
        _Path -> true
    end;
has_tests(Module, {eunit, Extra}) ->
    has_tests(Module, eunit) orelse any_contributes_tests(Extra);
has_tests(_Module, {ct, Suite}) ->
    case code:ensure_loaded(Suite) of
        {module, Suite} -> true;
        {error, _} -> false
    end.

%% Whether eunit:test(Module) would run anything: Module or <Module>_tests
%% exports a test function. Read from the beam on disk, so nothing is loaded.
-spec contributes_tests(module()) -> boolean().
contributes_tests(Module) ->
    exports_tests_on_disk(atom_to_list(Module)) orelse exports_tests_on_disk(tests_name(Module)).

-spec any_contributes_tests([module()]) -> boolean().
any_contributes_tests([]) -> false;
any_contributes_tests([Test | Rest]) -> contributes_tests(Test) orelse any_contributes_tests(Rest).

exports_tests_on_disk(Name) ->
    case code:where_is_file(Name ++ ".beam") of
        non_existing ->
            false;
        Path ->
            case beam_lib:chunks(Path, [exports]) of
                {ok, {_, [{exports, Exports}]}} -> lists:any(fun is_test_export/1, Exports);
                {error, beam_lib, _} -> false
            end
    end.

is_test_export({Name, 0}) -> is_test_name(atom_to_list(Name));
is_test_export({_Name, _Arity}) -> false.

tests_name(Module) ->
    atom_to_list(Module) ++ "_tests".

%% eunit:test/2 already runs <Module>_tests for Module, so listing it again
%% would run that suite twice per mutant.
-spec eunit_targets(module(), [module()]) -> [module()].
eunit_targets(Module, Extra) ->
    Implied = [atom_to_list(Module), tests_name(Module)],
    [Module | [M || M <- unique(Extra), not lists:member(atom_to_list(M), Implied)]].

-spec unique([module()]) -> [module()].
unique([]) -> [];
unique([Module | Rest]) -> [Module | unique([M || M <- Rest, M =/= Module])].

%%====================================================================
%% Test execution
%%====================================================================

execute(eunit, Module, Timeout) ->
    run_eunit(Module, Timeout);
execute({eunit, Extra}, Module, Timeout) ->
    run_eunit(eunit_targets(Module, Extra), Timeout);
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

run_eunit(Tests, Timeout) ->
    in_worker(fun() -> eunit_verdict(Tests) end, Timeout).

%% The shared eunit_server spawns test processes as its own children, out of
%% reach of the worker's group leader. A server started from the worker makes
%% the whole run descend from it, so stop_run/1 can find every process in it.
-spec eunit_verdict(module() | [module()]) -> pass | fail.
eunit_verdict(Tests) ->
    Server = eunit:start(undefined),
    try eunit:test(Server, Tests, [no_tty]) of
        ok -> pass;
        error -> fail
    catch
        _:_ -> fail
    end.

%% The worker sends before it exits, and signals between two processes keep
%% their order, so the result is always ahead of the DOWN in the mailbox.
-spec in_worker(fun(() -> Result), pos_integer()) -> Result | fail | timeout.
in_worker(Fun, Timeout) ->
    Parent = self(),
    Ref = make_ref(),
    Before = maps:from_keys(erlang:processes(), true),
    Original = group_leader(),
    Leader = spawn(fun() -> forward_io(Original, erlang:monitor(process, Parent)) end),
    {Pid, MRef} = spawn_monitor(fun() ->
        group_leader(Leader, self()),
        Parent ! {Ref, Fun()}
    end),
    Verdict =
        receive
            {Ref, Result} -> Result;
            {'DOWN', MRef, process, Pid, _Reason} -> fail
        after Timeout -> timeout
        end,
    erlang:demonitor(MRef, [flush]),
    stop_run(Leader, Before),
    Verdict.

-spec forward_io(pid(), reference()) -> ok.
forward_io(Original, CallerRef) ->
    receive
        {io_request, _From, _ReplyAs, _Request} = Request ->
            Original ! Request,
            forward_io(Original, CallerRef);
        {'DOWN', CallerRef, process, _Caller, _Reason} ->
            ok;
        _Other ->
            forward_io(Original, CallerRef)
    end.

%% Every process a run starts inherits Leader as its group leader, directly or
%% through one of eunit's own group leaders. eunit stops a test's group leader
%% when the test ends, and a dead process cannot be asked for its own, so a
%% chain that ends at a pid that died after the run began also counts: only a
%% process started during the run can have one. Killed pids stay known for the
%% same reason, and the sweep repeats until a pass finds nothing new, which
%% catches anything spawned while it ran.
-spec stop_run(pid(), #{pid() => true}) -> ok.
stop_run(Leader, Before) ->
    stop_members(#{Leader => true}, Before),
    exit(Leader, kill),
    ok.

-spec stop_members(#{pid() => true}, #{pid() => true}) -> ok.
stop_members(Known, Before) ->
    Self = self(),
    case
        [
            Pid
         || Pid <- erlang:processes(),
            Pid =/= Self,
            not is_map_key(Pid, Before),
            not is_map_key(Pid, Known),
            leads_to(Pid, Known, Before, [Pid])
        ]
    of
        [] ->
            ok;
        Members ->
            kill_and_await([{Pid, erlang:monitor(process, Pid)} || Pid <- Members]),
            stop_members(maps:merge(Known, maps:from_keys(Members, true)), Before)
    end.

-spec leads_to(pid(), #{pid() => true}, #{pid() => true}, [pid()]) -> boolean().
leads_to(Pid, Known, Before, Seen) ->
    case process_info(Pid, group_leader) of
        {group_leader, Leader} when is_map_key(Leader, Known) ->
            true;
        {group_leader, Leader} when node(Leader) =:= node() ->
            not lists:member(Leader, Seen) andalso
                (started_and_died(Leader, Before) orelse
                    leads_to(Leader, Known, Before, [Leader | Seen]));
        _ ->
            false
    end.

-spec started_and_died(pid(), #{pid() => true}) -> boolean().
started_and_died(Pid, Before) ->
    not is_map_key(Pid, Before) andalso not is_process_alive(Pid).

-spec kill_and_await([{pid(), reference()}]) -> ok.
kill_and_await([]) ->
    ok;
kill_and_await([{Pid, MRef} | Rest]) ->
    exit(Pid, kill),
    receive
        {'DOWN', MRef, process, Pid, _Reason} -> kill_and_await(Rest)
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
        {module, Module} -> purge_mutant(Module);
        {error, Reason} -> erlang:error({mutant_restore_failed, Module, Reason})
    end;
restore_module(Module, {beam_path, _Path}) ->
    purge(Module),
    case code:load_file(Module) of
        {module, Module} -> purge_mutant(Module);
        {error, Reason} -> erlang:error({mutant_restore_failed, Module, Reason})
    end.

%% stop_run/1 has already ended the run's own processes. One outside it still
%% running mutant code, such as a server a test started under an application,
%% is killed by purging the mutant, now the old version, before the next run.
purge_mutant(Module) ->
    _ = code:purge(Module),
    ok.

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
            lists:any(fun is_test_export/1, Module:module_info(exports));
        {error, _} ->
            false
    end.

is_test_name(Name) ->
    lists:suffix("_test", Name) orelse lists:suffix("_test_", Name).
