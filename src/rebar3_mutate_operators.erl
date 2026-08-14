-module(rebar3_mutate_operators).

-export([all/0, mutate_node/2]).

-type operator() ::
    op_arithmetic
    | op_relational
    | op_boolean
    | op_return_value
    | op_statement_delete
    | op_constant
    | op_negate_condition
    | op_list.
-type mutation() :: {operator(), erl_syntax:syntaxTree()}.

-export_type([operator/0, mutation/0]).

-spec all() -> [operator()].
all() ->
    [
        op_arithmetic,
        op_relational,
        op_boolean,
        op_return_value,
        op_statement_delete,
        op_constant,
        op_negate_condition,
        op_list
    ].

-spec mutate_node(erl_syntax:syntaxTree(), [operator()]) -> [mutation()].
mutate_node(Node, Operators) ->
    lists:flatmap(fun(Op) -> apply_operator(Op, Node) end, Operators).

%%====================================================================
%% Operators
%%====================================================================

apply_operator(op_arithmetic, Node) ->
    case erl_syntax:type(Node) of
        infix_expr ->
            case op_name(Node) of
                '+' -> [infix_mutation(op_arithmetic, Node, '-')];
                '-' -> [infix_mutation(op_arithmetic, Node, '+')];
                '*' -> [infix_mutation(op_arithmetic, Node, 'div')];
                'div' -> [infix_mutation(op_arithmetic, Node, '*')];
                'rem' -> [infix_mutation(op_arithmetic, Node, 'div')];
                _ -> []
            end;
        _ ->
            []
    end;
apply_operator(op_relational, Node) ->
    case erl_syntax:type(Node) of
        infix_expr ->
            case op_name(Node) of
                '>' -> [infix_mutation(op_relational, Node, '<')];
                '<' -> [infix_mutation(op_relational, Node, '>')];
                '>=' -> [infix_mutation(op_relational, Node, '=<')];
                '=<' -> [infix_mutation(op_relational, Node, '>=')];
                '=:=' -> [infix_mutation(op_relational, Node, '=/=')];
                '=/=' -> [infix_mutation(op_relational, Node, '=:=')];
                '==' -> [infix_mutation(op_relational, Node, '/=')];
                '/=' -> [infix_mutation(op_relational, Node, '==')];
                _ -> []
            end;
        _ ->
            []
    end;
apply_operator(op_boolean, Node) ->
    case erl_syntax:type(Node) of
        infix_expr ->
            case op_name(Node) of
                'andalso' -> [infix_mutation(op_boolean, Node, 'orelse')];
                'orelse' -> [infix_mutation(op_boolean, Node, 'andalso')];
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
            case erl_syntax:tuple_elements(Node) of
                [Tag | Rest] ->
                    case erl_syntax:type(Tag) of
                        atom ->
                            case erl_syntax:atom_value(Tag) of
                                ok -> [return_tuple_mutation(Node, Tag, error, Rest)];
                                error -> [return_tuple_mutation(Node, Tag, ok, Rest)];
                                _ -> []
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
    end;
apply_operator(op_statement_delete, Node) ->
    case erl_syntax:type(Node) of
        application ->
            [{op_statement_delete, erl_syntax:copy_pos(Node, erl_syntax:atom(ok))}];
        _ ->
            []
    end;
apply_operator(op_constant, Node) ->
    case erl_syntax:type(Node) of
        integer ->
            Val = erl_syntax:integer_value(Node),
            Mutations =
                [{op_constant, erl_syntax:copy_pos(Node, erl_syntax:integer(Val + 1))}] ++
                    [{op_constant, erl_syntax:copy_pos(Node, erl_syntax:integer(Val - 1))}] ++
                    case Val of
                        0 -> [];
                        _ -> [{op_constant, erl_syntax:copy_pos(Node, erl_syntax:integer(0))}]
                    end,
            Mutations;
        _ ->
            []
    end;
apply_operator(op_negate_condition, Node) ->
    case erl_syntax:type(Node) of
        prefix_expr ->
            Op = erl_syntax:prefix_expr_operator(Node),
            case erl_syntax:operator_name(Op) of
                'not' ->
                    [{op_negate_condition, erl_syntax:prefix_expr_argument(Node)}];
                _ ->
                    []
            end;
        infix_expr ->
            case op_name(Node) of
                Name when Name =:= 'andalso'; Name =:= 'orelse' ->
                    [
                        {op_negate_condition,
                            erl_syntax:copy_pos(
                                Node,
                                erl_syntax:prefix_expr(erl_syntax:operator('not'), Node)
                            )}
                    ];
                _ ->
                    []
            end;
        _ ->
            []
    end;
apply_operator(op_list, Node) ->
    case erl_syntax:type(Node) of
        infix_expr ->
            case op_name(Node) of
                '++' -> [infix_mutation(op_list, Node, '--')];
                '--' -> [infix_mutation(op_list, Node, '++')];
                _ -> []
            end;
        application ->
            case callee_name(erl_syntax:application_operator(Node)) of
                {ok, hd} -> swap_hd_tl(Node, tl);
                {ok, tl} -> swap_hd_tl(Node, hd);
                _ -> []
            end;
        _ ->
            []
    end.

%%====================================================================
%% Helpers
%%====================================================================

op_name(InfixNode) ->
    erl_syntax:operator_name(erl_syntax:infix_expr_operator(InfixNode)).

infix_mutation(Tag, Node, NewOp) ->
    Left = erl_syntax:infix_expr_left(Node),
    Right = erl_syntax:infix_expr_right(Node),
    Op = erl_syntax:infix_expr_operator(Node),
    NewNode = erl_syntax:copy_pos(
        Node,
        erl_syntax:infix_expr(Left, erl_syntax:copy_pos(Op, erl_syntax:operator(NewOp)), Right)
    ),
    {Tag, NewNode}.

return_tuple_mutation(Node, Tag, NewAtom, Rest) ->
    NewTag = erl_syntax:copy_pos(Tag, erl_syntax:atom(NewAtom)),
    {op_return_value, erl_syntax:copy_pos(Node, erl_syntax:tuple([NewTag | Rest]))}.

%% Matches a local call or an explicit erlang:F/N call. Reading the callee
%% through erl_syntax rather than an erl_parse tuple pattern matters: the
%% pattern only fired on unrevented trees, so the operator produced a
%% different mutation count depending on how the node reached it.
callee_name(Operator) ->
    case erl_syntax:type(Operator) of
        atom ->
            {ok, erl_syntax:atom_value(Operator)};
        module_qualifier ->
            Module = erl_syntax:module_qualifier_argument(Operator),
            Function = erl_syntax:module_qualifier_body(Operator),
            case {erl_syntax:type(Module), erl_syntax:type(Function)} of
                {atom, atom} ->
                    case erl_syntax:atom_value(Module) of
                        erlang -> {ok, erl_syntax:atom_value(Function)};
                        _ -> none
                    end;
                _ ->
                    none
            end;
        _ ->
            none
    end.

swap_hd_tl(Node, NewName) ->
    Args = erl_syntax:application_arguments(Node),
    NewOp = rename_callee(erl_syntax:application_operator(Node), NewName),
    [{op_list, erl_syntax:copy_pos(Node, erl_syntax:application(NewOp, Args))}].

rename_callee(Operator, NewName) ->
    case erl_syntax:type(Operator) of
        module_qualifier ->
            Module = erl_syntax:module_qualifier_argument(Operator),
            Function = erl_syntax:module_qualifier_body(Operator),
            erl_syntax:copy_pos(
                Operator,
                erl_syntax:module_qualifier(
                    Module,
                    erl_syntax:copy_pos(Function, erl_syntax:atom(NewName))
                )
            );
        _ ->
            erl_syntax:copy_pos(Operator, erl_syntax:atom(NewName))
    end.
