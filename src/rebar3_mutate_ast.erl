-module(rebar3_mutate_ast).

-export([
    parse_file/2,
    mutation_points/2,
    mutation_points/3,
    apply_mutation/3,
    describe_mutation/1,
    function_ranges/1
]).

-record(mutation_point, {
    index :: non_neg_integer(),
    operator :: rebar3_mutate_operators:operator(),
    line :: non_neg_integer(),
    original :: erl_syntax:syntaxTree(),
    mutated :: erl_syntax:syntaxTree()
}).

-type mutation_point() :: #mutation_point{}.
-export_type([mutation_point/0]).

-spec parse_file(file:filename(), [file:filename()]) ->
    {ok, atom(), [erl_parse:abstract_form()]} | {error, term()}.
parse_file(File, IncludeDirs) ->
    Opts = [{includes, IncludeDirs}, {macros, [{'TEST', true}]}],
    case epp:parse_file(File, Opts) of
        {ok, Forms} ->
            Module = extract_module(Forms),
            {ok, Module, Forms};
        {error, _} = Err ->
            Err
    end.

-spec mutation_points([erl_parse:abstract_form()], [rebar3_mutate_operators:operator()]) ->
    [mutation_point()].
mutation_points(Forms, Operators) ->
    Tree = erl_syntax:form_list(Forms),
    {_, Points} = erl_syntax_lib:fold(
        fun(Node, Acc) ->
            Mutations = rebar3_mutate_operators:mutate_node(Node, Operators),
            Line = get_line(Node),
            lists:foldl(
                fun({Op, Mutated}, {Idx, Pts}) ->
                    Point = #mutation_point{
                        index = Idx,
                        operator = Op,
                        line = Line,
                        original = Node,
                        mutated = Mutated
                    },
                    {Idx + 1, [Point | Pts]}
                end,
                Acc,
                Mutations
            )
        end,
        {0, []},
        Tree
    ),
    lists:reverse(Points).

-spec mutation_points([erl_parse:abstract_form()], [rebar3_mutate_operators:operator()], [
    pos_integer()
]) ->
    [mutation_point()].
mutation_points(Forms, Operators, Lines) ->
    AllPoints = mutation_points(Forms, Operators),
    [P || #mutation_point{line = L} = P <- AllPoints, lists:member(L, Lines)].

-spec apply_mutation([erl_parse:abstract_form()], mutation_point(), [
    rebar3_mutate_operators:operator()
]) ->
    [erl_parse:abstract_form()].
apply_mutation(Forms, #mutation_point{index = TargetIdx, mutated = Mutated} = _Point, Operators) ->
    Tree = erl_syntax:form_list(Forms),
    {NewTree, _} = erl_syntax_lib:mapfold(
        fun(Node, Idx) ->
            Mutations = rebar3_mutate_operators:mutate_node(Node, Operators),
            case Mutations of
                [] ->
                    {Node, Idx};
                _ ->
                    NewIdx = Idx + length(Mutations),
                    case TargetIdx >= Idx andalso TargetIdx < NewIdx of
                        true ->
                            {Mutated, NewIdx};
                        false ->
                            {Node, NewIdx}
                    end
            end
        end,
        0,
        Tree
    ),
    erl_syntax:revert_forms(NewTree).

-spec describe_mutation(mutation_point()) -> iolist().
describe_mutation(#mutation_point{operator = Op, line = Line, original = Orig, mutated = Mut}) ->
    OrigStr =
        try
            erl_prettypr:format(Orig, [{paper, 80}, {ribbon, 60}])
        catch
            _:_ -> "?"
        end,
    MutStr =
        try
            erl_prettypr:format(Mut, [{paper, 80}, {ribbon, 60}])
        catch
            _:_ -> "?"
        end,
    io_lib:format("line ~B [~s] ~s -> ~s", [Line, Op, OrigStr, MutStr]).

-spec function_ranges([erl_parse:abstract_form()]) ->
    [{atom(), arity(), pos_integer(), pos_integer()}].
function_ranges(Forms) ->
    lists:filtermap(
        fun
            ({function, Line, Name, Arity, Clauses}) ->
                EndLine = last_clause_line(Clauses, Line),
                {true, {Name, Arity, Line, EndLine}};
            (_) ->
                false
        end,
        Forms
    ).

%%====================================================================
%% Internal
%%====================================================================

last_clause_line([], Default) ->
    Default;
last_clause_line(Clauses, _Default) ->
    LastClause = lists:last(Clauses),
    clause_end_line(LastClause).

clause_end_line({clause, Line, _, _, Body}) ->
    case Body of
        [] ->
            Line;
        _ ->
            LastExpr = lists:last(Body),
            expr_line(LastExpr, Line)
    end.

expr_line(Expr, Default) ->
    case Expr of
        {_, Line, _, _} when is_integer(Line) -> Line;
        {_, Line, _} when is_integer(Line) -> Line;
        {_, Line} when is_integer(Line) -> Line;
        _ -> Default
    end.

extract_module([{attribute, _, module, Mod} | _]) -> Mod;
extract_module([_ | Rest]) -> extract_module(Rest);
extract_module([]) -> undefined.

get_line(Node) ->
    Pos = erl_syntax:get_pos(Node),
    try
        erl_anno:line(Pos)
    catch
        _:_ -> 0
    end.
