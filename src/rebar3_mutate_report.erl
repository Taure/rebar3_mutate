-module(rebar3_mutate_report).

-export([format/2]).

-spec format(atom(), [
    {rebar3_mutate_ast:mutation_point(), killed | survived | timed_out | {compile_error, term()}}
]) -> ok.
format(Module, Results) ->
    Total = length(Results),
    Killed = length([R || {_, R} <- Results, R =:= killed]),
    Survived = length([R || {_, R} <- Results, R =:= survived]),
    TimedOut = length([R || {_, R} <- Results, R =:= timed_out]),
    CompileErrors = length([R || {_, R} <- Results, is_compile_error(R)]),
    Score =
        case Total - CompileErrors of
            0 -> 0.0;
            Testable -> (Killed / Testable) * 100
        end,

    rebar_api:info("~n~s", [string:copies("=", 60)]),
    rebar_api:info("Module: ~s (~B mutants, ~B killed, ~B survived, ~B timed out~s)", [
        Module,
        Total,
        Killed,
        Survived,
        TimedOut,
        case CompileErrors of
            0 -> "";
            N -> io_lib:format(", ~B compile errors", [N])
        end
    ]),
    rebar_api:info("Score:  ~.1f%", [Score]),

    case [R || {_, S} = R <- Results, S =:= survived] of
        [] ->
            ok;
        SurvivedList ->
            rebar_api:info("~nSurviving mutants:", []),
            lists:foreach(
                fun({Point, _}) ->
                    Desc = rebar3_mutate_ast:describe_mutation(Point),
                    rebar_api:info("  ~s", [Desc])
                end,
                SurvivedList
            )
    end,

    case [R || {_, S} = R <- Results, S =:= timed_out] of
        [] ->
            ok;
        TimedOutList ->
            rebar_api:info("~nTimed out mutants:", []),
            lists:foreach(
                fun({Point, _}) ->
                    Desc = rebar3_mutate_ast:describe_mutation(Point),
                    rebar_api:info("  ~s", [Desc])
                end,
                TimedOutList
            )
    end,

    rebar_api:info("~s~n", [string:copies("=", 60)]),
    ok.

%%====================================================================
%% Internal
%%====================================================================

is_compile_error({compile_error, _}) -> true;
is_compile_error(_) -> false.
