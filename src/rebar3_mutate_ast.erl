-module(rebar3_mutate_ast).

-export([parse_file/2, mutation_points/2, apply_mutation/3, describe_mutation/1]).

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

%%====================================================================
%% Internal
%%====================================================================

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
