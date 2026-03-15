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
    | op_list
    | op_guard
    | op_exception
    | op_map
    | op_binary
    | op_clause_swap
    | op_receive.
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
        op_list,
        op_guard,
        op_exception,
        op_map,
        op_binary,
        op_clause_swap,
        op_receive
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
            case erl_syntax:application_operator(Node) of
                {_, _, {_, _, erlang}, {_, _, hd}} ->
                    swap_hd_tl(Node, tl);
                {_, _, {_, _, erlang}, {_, _, tl}} ->
                    swap_hd_tl(Node, hd);
                _ ->
                    case erl_syntax:type(erl_syntax:application_operator(Node)) of
                        atom ->
                            case erl_syntax:atom_value(erl_syntax:application_operator(Node)) of
                                hd -> swap_hd_tl(Node, tl);
                                tl -> swap_hd_tl(Node, hd);
                                _ -> []
                            end;
                        _ ->
                            []
                    end
            end;
        _ ->
            []
    end;
%%====================================================================
%% New operators — Phase 2/3
%%====================================================================

%% Guard removal: remove guard expressions by replacing with 'true'
apply_operator(op_guard, Node) ->
    case erl_syntax:type(Node) of
        application ->
            case erl_syntax:application_operator(Node) of
                _ ->
                    case erl_syntax:type(erl_syntax:application_operator(Node)) of
                        atom ->
                            FnName = erl_syntax:atom_value(erl_syntax:application_operator(Node)),
                            case is_guard_bif(FnName) of
                                true ->
                                    [{op_guard, erl_syntax:copy_pos(Node, erl_syntax:atom(true))}];
                                false ->
                                    []
                            end;
                        _ ->
                            []
                    end
            end;
        _ ->
            []
    end;
%% Exception mutations: swap throw/error/exit
apply_operator(op_exception, Node) ->
    case erl_syntax:type(Node) of
        application ->
            case erl_syntax:application_operator(Node) of
                _ ->
                    case erl_syntax:type(erl_syntax:application_operator(Node)) of
                        atom ->
                            FnName = erl_syntax:atom_value(erl_syntax:application_operator(Node)),
                            Args = erl_syntax:application_arguments(Node),
                            case {FnName, length(Args)} of
                                {throw, 1} ->
                                    [{op_exception, replace_fn(Node, error, Args)}];
                                {error, 1} ->
                                    [{op_exception, replace_fn(Node, throw, Args)}];
                                {exit, 1} ->
                                    [{op_exception, replace_fn(Node, throw, Args)}];
                                _ ->
                                    []
                            end;
                        _ ->
                            []
                    end
            end;
        _ ->
            []
    end;
%% Map mutations: maps:get/2 -> maps:get/3 with wrong default, remove map fields
apply_operator(op_map, Node) ->
    case erl_syntax:type(Node) of
        map_expr ->
            Fields = erl_syntax:map_expr_fields(Node),
            case Fields of
                [_ | _] when length(Fields) > 1 ->
                    %% Remove the first field
                    [_ | RestFields] = Fields,
                    Arg = erl_syntax:map_expr_argument(Node),
                    NewMap =
                        case Arg of
                            none ->
                                erl_syntax:copy_pos(Node, erl_syntax:map_expr(RestFields));
                            _ ->
                                erl_syntax:copy_pos(Node, erl_syntax:map_expr(Arg, RestFields))
                        end,
                    [{op_map, NewMap}];
                _ ->
                    []
            end;
        _ ->
            []
    end;
%% Binary mutations: swap big/little endianness in bit syntax qualifiers
apply_operator(op_binary, Node) ->
    case erl_syntax:type(Node) of
        binary ->
            Fields = erl_syntax:binary_fields(Node),
            mutate_binary_fields(Node, Fields);
        _ ->
            []
    end;
%% Clause swap: swap first two clauses in case/if expressions
apply_operator(op_clause_swap, Node) ->
    case erl_syntax:type(Node) of
        case_expr ->
            Clauses = erl_syntax:case_expr_clauses(Node),
            case Clauses of
                [C1, C2 | Rest] ->
                    Arg = erl_syntax:case_expr_argument(Node),
                    NewNode = erl_syntax:copy_pos(
                        Node,
                        erl_syntax:case_expr(Arg, [C2, C1 | Rest])
                    ),
                    [{op_clause_swap, NewNode}];
                _ ->
                    []
            end;
        _ ->
            []
    end;
%% Receive mutations: modify after timeout value
apply_operator(op_receive, Node) ->
    case erl_syntax:type(Node) of
        receive_expr ->
            Timeout = erl_syntax:receive_expr_timeout(Node),
            case Timeout of
                none ->
                    [];
                _ ->
                    case erl_syntax:type(Timeout) of
                        integer ->
                            Val = erl_syntax:integer_value(Timeout),
                            Clauses = erl_syntax:receive_expr_clauses(Node),
                            Action = erl_syntax:receive_expr_action(Node),
                            NewTimeout = erl_syntax:integer(Val + 1),
                            NewNode = erl_syntax:copy_pos(
                                Node,
                                erl_syntax:receive_expr(Clauses, NewTimeout, Action)
                            ),
                            [{op_receive, NewNode}];
                        atom ->
                            case erl_syntax:atom_value(Timeout) of
                                infinity ->
                                    Clauses = erl_syntax:receive_expr_clauses(Node),
                                    Action = erl_syntax:receive_expr_action(Node),
                                    NewTimeout = erl_syntax:integer(0),
                                    NewNode = erl_syntax:copy_pos(
                                        Node,
                                        erl_syntax:receive_expr(Clauses, NewTimeout, Action)
                                    ),
                                    [{op_receive, NewNode}];
                                _ ->
                                    []
                            end;
                        _ ->
                            []
                    end
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

swap_hd_tl(Node, NewName) ->
    Args = erl_syntax:application_arguments(Node),
    Operator = erl_syntax:application_operator(Node),
    NewOp = erl_syntax:copy_pos(Operator, erl_syntax:atom(NewName)),
    [{op_list, erl_syntax:copy_pos(Node, erl_syntax:application(NewOp, Args))}].

replace_fn(Node, NewName, Args) ->
    Operator = erl_syntax:application_operator(Node),
    NewOp = erl_syntax:copy_pos(Operator, erl_syntax:atom(NewName)),
    erl_syntax:copy_pos(Node, erl_syntax:application(NewOp, Args)).

is_guard_bif(is_atom) -> true;
is_guard_bif(is_binary) -> true;
is_guard_bif(is_boolean) -> true;
is_guard_bif(is_float) -> true;
is_guard_bif(is_function) -> true;
is_guard_bif(is_integer) -> true;
is_guard_bif(is_list) -> true;
is_guard_bif(is_map) -> true;
is_guard_bif(is_number) -> true;
is_guard_bif(is_pid) -> true;
is_guard_bif(is_port) -> true;
is_guard_bif(is_reference) -> true;
is_guard_bif(is_tuple) -> true;
is_guard_bif(is_record) -> true;
is_guard_bif(_) -> false.

mutate_binary_fields(Node, Fields) ->
    case has_size_spec(Fields) of
        true ->
            %% Mutate the size of the first sized field by +1
            {NewFields, Changed} = lists:mapfoldl(
                fun
                    (Field, false) ->
                        case erl_syntax:binary_field_size(Field) of
                            none ->
                                {Field, false};
                            Size ->
                                case erl_syntax:type(Size) of
                                    integer ->
                                        Val = erl_syntax:integer_value(Size),
                                        NewSize = erl_syntax:integer(Val + 1),
                                        Body = erl_syntax:binary_field_body(Field),
                                        Types = erl_syntax:binary_field_types(Field),
                                        NewField = erl_syntax:binary_field(Body, NewSize, Types),
                                        {NewField, true};
                                    _ ->
                                        {Field, false}
                                end
                        end;
                    (Field, true) ->
                        {Field, true}
                end,
                false,
                Fields
            ),
            case Changed of
                true ->
                    [{op_binary, erl_syntax:copy_pos(Node, erl_syntax:binary(NewFields))}];
                false ->
                    []
            end;
        false ->
            []
    end.

has_size_spec([]) ->
    false;
has_size_spec([Field | Rest]) ->
    case erl_syntax:binary_field_size(Field) of
        none -> has_size_spec(Rest);
        _ -> true
    end.
