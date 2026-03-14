-module(rebar3_mutate_operators).

-export([all/0, mutate_node/2]).

-type operator() :: op_arithmetic | op_relational | op_boolean | op_return_value.
-type mutation() :: {operator(), erl_syntax:syntaxTree()}.

-export_type([operator/0, mutation/0]).

-spec all() -> [operator()].
all() ->
    [op_arithmetic, op_relational, op_boolean, op_return_value].

-spec mutate_node(erl_syntax:syntaxTree(), [operator()]) -> [mutation()].
mutate_node(Node, Operators) ->
    lists:flatmap(fun(Op) -> apply_operator(Op, Node) end, Operators).

%%====================================================================
%% Operators
%%====================================================================

apply_operator(op_arithmetic, Node) ->
    case erl_syntax:type(Node) of
        infix_expr ->
            Op = erl_syntax:infix_expr_operator(Node),
            case erl_syntax:operator_name(Op) of
                '+' -> [arith_mutation(Node, '-')];
                '-' -> [arith_mutation(Node, '+')];
                '*' -> [arith_mutation(Node, 'div')];
                'div' -> [arith_mutation(Node, '*')];
                'rem' -> [arith_mutation(Node, 'div')];
                _ -> []
            end;
        _ ->
            []
    end;
apply_operator(op_relational, Node) ->
    case erl_syntax:type(Node) of
        infix_expr ->
            Op = erl_syntax:infix_expr_operator(Node),
            case erl_syntax:operator_name(Op) of
                '>' -> [rel_mutation(Node, '<')];
                '<' -> [rel_mutation(Node, '>')];
                '>=' -> [rel_mutation(Node, '=<')];
                '=<' -> [rel_mutation(Node, '>=')];
                '=:=' -> [rel_mutation(Node, '=/=')];
                '=/=' -> [rel_mutation(Node, '=:=')];
                '==' -> [rel_mutation(Node, '/=')];
                '/=' -> [rel_mutation(Node, '==')];
                _ -> []
            end;
        _ ->
            []
    end;
apply_operator(op_boolean, Node) ->
    case erl_syntax:type(Node) of
        infix_expr ->
            Op = erl_syntax:infix_expr_operator(Node),
            case erl_syntax:operator_name(Op) of
                'andalso' -> [bool_mutation(Node, 'orelse')];
                'orelse' -> [bool_mutation(Node, 'andalso')];
                _ -> []
            end;
        atom ->
            case erl_syntax:atom_value(Node) of
                true -> [{op_boolean, erl_syntax:copy_pos(Node, erl_syntax:atom(false))}];
                false -> [{op_boolean, erl_syntax:copy_pos(Node, erl_syntax:atom(true))}];
                _ -> []
            end;
        _ ->
            []
    end;
apply_operator(op_return_value, Node) ->
    case erl_syntax:type(Node) of
        tuple ->
            Elements = erl_syntax:tuple_elements(Node),
            case Elements of
                [Tag | Rest] ->
                    case erl_syntax:type(Tag) of
                        atom ->
                            case erl_syntax:atom_value(Tag) of
                                ok ->
                                    NewTag = erl_syntax:copy_pos(Tag, erl_syntax:atom(error)),
                                    [
                                        {op_return_value,
                                            erl_syntax:copy_pos(
                                                Node, erl_syntax:tuple([NewTag | Rest])
                                            )}
                                    ];
                                error ->
                                    NewTag = erl_syntax:copy_pos(Tag, erl_syntax:atom(ok)),
                                    [
                                        {op_return_value,
                                            erl_syntax:copy_pos(
                                                Node, erl_syntax:tuple([NewTag | Rest])
                                            )}
                                    ];
                                _ ->
                                    []
                            end;
                        _ ->
                            []
                    end;
                _ ->
                    []
            end;
        atom ->
            case erl_syntax:atom_value(Node) of
                ok -> [{op_return_value, erl_syntax:copy_pos(Node, erl_syntax:atom(error))}];
                error -> [{op_return_value, erl_syntax:copy_pos(Node, erl_syntax:atom(ok))}];
                _ -> []
            end;
        _ ->
            []
    end.

%%====================================================================
%% Helpers
%%====================================================================

arith_mutation(Node, NewOp) ->
    Left = erl_syntax:infix_expr_left(Node),
    Right = erl_syntax:infix_expr_right(Node),
    Op = erl_syntax:infix_expr_operator(Node),
    NewNode = erl_syntax:copy_pos(
        Node,
        erl_syntax:infix_expr(Left, erl_syntax:copy_pos(Op, erl_syntax:operator(NewOp)), Right)
    ),
    {op_arithmetic, NewNode}.

rel_mutation(Node, NewOp) ->
    Left = erl_syntax:infix_expr_left(Node),
    Right = erl_syntax:infix_expr_right(Node),
    Op = erl_syntax:infix_expr_operator(Node),
    NewNode = erl_syntax:copy_pos(
        Node,
        erl_syntax:infix_expr(Left, erl_syntax:copy_pos(Op, erl_syntax:operator(NewOp)), Right)
    ),
    {op_relational, NewNode}.

bool_mutation(Node, NewOp) ->
    Left = erl_syntax:infix_expr_left(Node),
    Right = erl_syntax:infix_expr_right(Node),
    Op = erl_syntax:infix_expr_operator(Node),
    NewNode = erl_syntax:copy_pos(
        Node,
        erl_syntax:infix_expr(Left, erl_syntax:copy_pos(Op, erl_syntax:operator(NewOp)), Right)
    ),
    {op_boolean, NewNode}.
