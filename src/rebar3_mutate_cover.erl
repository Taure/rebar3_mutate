-module(rebar3_mutate_cover).

-export([gather_coverage/2, modules_covering/2]).

-spec gather_coverage(eunit | {ct, atom()}, [atom()]) ->
    #{atom() => [pos_integer()]}.
gather_coverage(TestSpec, Modules) ->
    _ = cover:start(),
    lists:foreach(fun(M) -> cover:compile_beam(M) end, Modules),
    run_all_tests(TestSpec, Modules),
    Coverage = lists:foldl(
        fun(Mod, Acc) ->
            Lines = covered_lines(Mod),
            Acc#{Mod => Lines}
        end,
        #{},
        Modules
    ),
    _ = cover:stop(),
    Coverage.

-spec modules_covering(#{atom() => [pos_integer()]}, {atom(), pos_integer()}) ->
    boolean().
modules_covering(Coverage, {Module, Line}) ->
    case maps:find(Module, Coverage) of
        {ok, Lines} -> lists:member(Line, Lines);
        error -> true
    end.

%%====================================================================
%% Internal
%%====================================================================

run_all_tests(eunit, Modules) ->
    lists:foreach(
        fun(M) ->
            try
                eunit:test(M, [no_tty])
            catch
                _:_ -> ok
            end
        end,
        Modules
    );
run_all_tests({ct, Suite}, _Modules) ->
    try
        ct:run_test([{suite, Suite}, {logopts, [no_src]}, {verbosity, 0}])
    catch
        _:_ -> ok
    end.

covered_lines(Module) ->
    case cover:analyse(Module, coverage, line) of
        {ok, Results} ->
            [Line || {{_Mod, Line}, {Count, _}} <- Results, Count > 0];
        {error, _} ->
            []
    end.
