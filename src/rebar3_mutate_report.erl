-module(rebar3_mutate_report).

-export([format/2, format_json/2, count/1, total_count/1, score/1, testable/1]).

-type verdict() :: rebar3_mutate_runner:verdict().
-type results() :: [{rebar3_mutate_ast:mutation_point(), verdict()}].
-type counts() :: #{atom() => non_neg_integer()}.

-export_type([counts/0, results/0]).

-spec count(results()) -> counts().
count(Results) ->
    Verdicts = [verdict_key(Verdict) || {_Point, Verdict} <- Results],
    #{
        killed => tally(killed, Verdicts),
        survived => tally(survived, Verdicts),
        timed_out => tally(timed_out, Verdicts),
        compile_errors => tally(compile_errors, Verdicts),
        skipped => tally(skipped, Verdicts),
        total => length(Verdicts)
    }.

-spec total_count([{atom(), results()}]) -> counts().
total_count(AllResults) ->
    count(lists:append([Results || {_Module, Results} <- AllResults])).

%% Mutants that never ran a test - compile errors and skips - are excluded from
%% the denominator. Console output and the --min-score gate both come from
%% here, so the number reported is the number gated on.
-spec testable(counts()) -> non_neg_integer().
testable(#{killed := K, survived := S, timed_out := T}) -> K + S + T.

-spec score(counts()) -> float().
score(Counts) ->
    case testable(Counts) of
        0 -> 0.0;
        Testable -> round(maps:get(killed, Counts) / Testable * 1000) / 10
    end.

-spec format(atom(), results()) -> ok.
format(Module, Results) ->
    Counts = count(Results),
    rebar_api:info("~n~s", [string:copies("=", 60)]),
    rebar_api:info("Module: ~s (~B mutants: ~B killed, ~B survived, ~B timed out~s)", [
        Module,
        maps:get(total, Counts),
        maps:get(killed, Counts),
        maps:get(survived, Counts),
        maps:get(timed_out, Counts),
        excluded_suffix(Counts)
    ]),
    rebar_api:info("Score:  ~.1f% (~B killed of ~B testable)", [
        score(Counts), maps:get(killed, Counts), testable(Counts)
    ]),
    list_mutants("Surviving mutants", survived, Results),
    list_mutants("Timed out mutants", timed_out, Results),
    list_skipped(Results),
    rebar_api:info("~s~n", [string:copies("=", 60)]),
    ok.

-spec format_json([{atom(), results()}], [{atom(), term()}]) -> iodata().
format_json(AllResults, SkippedModules) ->
    Counts = total_count(AllResults),
    encode(
        {obj, [
            {~"overall_score", score(Counts)},
            {~"total_mutants", maps:get(total, Counts)},
            {~"total_killed", maps:get(killed, Counts)},
            {~"total_survived", maps:get(survived, Counts)},
            {~"total_timed_out", maps:get(timed_out, Counts)},
            {~"total_compile_errors", maps:get(compile_errors, Counts)},
            {~"total_skipped", maps:get(skipped, Counts)},
            {~"testable", testable(Counts)},
            {~"modules", [module_json(M, R) || {M, R} <- AllResults]},
            {~"skipped_modules", [skipped_json(M, Reason) || {M, Reason} <- SkippedModules]}
        ]}
    ).

%%====================================================================
%% Internal
%%====================================================================

module_json(Module, Results) ->
    Counts = count(Results),
    {obj, [
        {~"module", atom_to_binary(Module)},
        {~"total", maps:get(total, Counts)},
        {~"killed", maps:get(killed, Counts)},
        {~"survived", maps:get(survived, Counts)},
        {~"timed_out", maps:get(timed_out, Counts)},
        {~"compile_errors", maps:get(compile_errors, Counts)},
        {~"skipped", maps:get(skipped, Counts)},
        {~"testable", testable(Counts)},
        {~"score", score(Counts)},
        {~"surviving_mutants", mutants_json(survived, Results)},
        {~"timed_out_mutants", mutants_json(timed_out, Results)}
    ]}.

skipped_json(Module, Reason) ->
    {obj, [
        {~"module", atom_to_binary(Module)},
        {~"reason", iolist_to_binary(io_lib:format("~p", [Reason]))}
    ]}.

mutants_json(Verdict, Results) ->
    [mutant_json(Point) || {Point, V} <- Results, V =:= Verdict].

mutant_json(Point) ->
    {obj, [
        {~"file", unicode:characters_to_binary(rebar3_mutate_ast:get_point_file(Point))},
        {~"line", rebar3_mutate_ast:get_point_line(Point)},
        {~"operator", atom_to_binary(rebar3_mutate_ast:get_point_operator(Point))},
        {~"description", iolist_to_binary(rebar3_mutate_ast:describe_mutation(Point))}
    ]}.

%% json:encode/2 with a tagged-object encoder rather than maps, because the
%% erlang-ci action anchors on overall_score being the first key and map
%% iteration order is not the insertion order.
encode(Term) ->
    json:encode(Term, fun encoder/2).

encoder({obj, KeyValues}, Encode) -> json:encode_key_value_list(KeyValues, Encode);
encoder(Other, Encode) -> json:encode_value(Other, Encode).

verdict_key(killed) -> killed;
verdict_key(survived) -> survived;
verdict_key(timed_out) -> timed_out;
verdict_key({compile_error, _}) -> compile_errors;
verdict_key({skipped, _}) -> skipped.

tally(Key, Verdicts) ->
    length([Verdict || Verdict <- Verdicts, Verdict =:= Key]).

excluded_suffix(Counts) ->
    Parts =
        [
            io_lib:format("~B compile errors", [maps:get(compile_errors, Counts)])
         || maps:get(compile_errors, Counts) > 0
        ] ++
            [
                io_lib:format("~B skipped", [maps:get(skipped, Counts)])
             || maps:get(skipped, Counts) > 0
            ],
    case Parts of
        [] -> "";
        _ -> [", ", lists:join(", ", Parts), " excluded"]
    end.

list_mutants(Heading, Verdict, Results) ->
    case [Point || {Point, V} <- Results, V =:= Verdict] of
        [] ->
            ok;
        Points ->
            rebar_api:info("~n~s:", [Heading]),
            lists:foreach(
                fun(Point) ->
                    rebar_api:info("  ~s:~s", [
                        filename:basename(rebar3_mutate_ast:get_point_file(Point)),
                        rebar3_mutate_ast:describe_mutation(Point)
                    ])
                end,
                Points
            )
    end.

list_skipped(Results) ->
    case [Reason || {_Point, {skipped, Reason}} <- Results] of
        [] ->
            ok;
        Reasons ->
            rebar_api:warn("~B mutant(s) skipped: ~p", [
                length(Reasons), lists:usort(Reasons)
            ])
    end.
