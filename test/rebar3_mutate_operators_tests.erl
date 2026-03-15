-module(rebar3_mutate_operators_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Arithmetic
%%====================================================================

arithmetic_plus_test() ->
    Node = make_infix(erl_syntax:integer(1), '+', erl_syntax:integer(2)),
    [{op_arithmetic, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_arithmetic]),
    ?assertEqual('-', get_op(Mutated)).

arithmetic_minus_test() ->
    Node = make_infix(erl_syntax:integer(1), '-', erl_syntax:integer(2)),
    [{op_arithmetic, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_arithmetic]),
    ?assertEqual('+', get_op(Mutated)).

arithmetic_multiply_test() ->
    Node = make_infix(erl_syntax:integer(3), '*', erl_syntax:integer(4)),
    [{op_arithmetic, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_arithmetic]),
    ?assertEqual('div', get_op(Mutated)).

arithmetic_div_test() ->
    Node = make_infix(erl_syntax:integer(10), 'div', erl_syntax:integer(2)),
    [{op_arithmetic, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_arithmetic]),
    ?assertEqual('*', get_op(Mutated)).

arithmetic_rem_test() ->
    Node = make_infix(erl_syntax:integer(10), 'rem', erl_syntax:integer(3)),
    [{op_arithmetic, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_arithmetic]),
    ?assertEqual('div', get_op(Mutated)).

arithmetic_no_match_test() ->
    Node = erl_syntax:atom(hello),
    ?assertEqual([], rebar3_mutate_operators:mutate_node(Node, [op_arithmetic])).

%%====================================================================
%% Relational
%%====================================================================

relational_gt_test() ->
    Node = make_infix(erl_syntax:integer(1), '>', erl_syntax:integer(2)),
    [{op_relational, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_relational]),
    ?assertEqual('<', get_op(Mutated)).

relational_lt_test() ->
    Node = make_infix(erl_syntax:integer(1), '<', erl_syntax:integer(2)),
    [{op_relational, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_relational]),
    ?assertEqual('>', get_op(Mutated)).

relational_exact_eq_test() ->
    Node = make_infix(erl_syntax:integer(1), '=:=', erl_syntax:integer(1)),
    [{op_relational, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_relational]),
    ?assertEqual('=/=', get_op(Mutated)).

relational_exact_neq_test() ->
    Node = make_infix(erl_syntax:integer(1), '=/=', erl_syntax:integer(2)),
    [{op_relational, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_relational]),
    ?assertEqual('=:=', get_op(Mutated)).

relational_gte_test() ->
    Node = make_infix(erl_syntax:integer(1), '>=', erl_syntax:integer(2)),
    [{op_relational, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_relational]),
    ?assertEqual('=<', get_op(Mutated)).

relational_lte_test() ->
    Node = make_infix(erl_syntax:integer(1), '=<', erl_syntax:integer(2)),
    [{op_relational, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_relational]),
    ?assertEqual('>=', get_op(Mutated)).

relational_struct_eq_test() ->
    Node = make_infix(erl_syntax:integer(1), '==', erl_syntax:integer(2)),
    [{op_relational, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_relational]),
    ?assertEqual('/=', get_op(Mutated)).

relational_struct_neq_test() ->
    Node = make_infix(erl_syntax:integer(1), '/=', erl_syntax:integer(2)),
    [{op_relational, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_relational]),
    ?assertEqual('==', get_op(Mutated)).

relational_no_match_test() ->
    Node = make_infix(erl_syntax:integer(1), '+', erl_syntax:integer(2)),
    ?assertEqual([], rebar3_mutate_operators:mutate_node(Node, [op_relational])).

%%====================================================================
%% Boolean
%%====================================================================

boolean_andalso_test() ->
    Node = make_infix(erl_syntax:atom(true), 'andalso', erl_syntax:atom(false)),
    Results = rebar3_mutate_operators:mutate_node(Node, [op_boolean]),
    OpNames = [Op || {Op, _} <- Results],
    ?assert(lists:member(op_boolean, OpNames)),
    [{op_boolean, Mutated} | _] = Results,
    ?assertEqual('orelse', get_op(Mutated)).

boolean_true_test() ->
    Node = erl_syntax:atom(true),
    [{op_boolean, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_boolean]),
    ?assertEqual(false, erl_syntax:atom_value(Mutated)).

boolean_false_test() ->
    Node = erl_syntax:atom(false),
    [{op_boolean, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_boolean]),
    ?assertEqual(true, erl_syntax:atom_value(Mutated)).

boolean_other_atom_test() ->
    Node = erl_syntax:atom(hello),
    ?assertEqual([], rebar3_mutate_operators:mutate_node(Node, [op_boolean])).

%%====================================================================
%% Return value
%%====================================================================

return_ok_atom_test() ->
    Node = erl_syntax:atom(ok),
    [{op_return_value, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_return_value]),
    ?assertEqual(error, erl_syntax:atom_value(Mutated)).

return_error_atom_test() ->
    Node = erl_syntax:atom(error),
    [{op_return_value, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_return_value]),
    ?assertEqual(ok, erl_syntax:atom_value(Mutated)).

return_ok_tuple_test() ->
    Node = erl_syntax:tuple([erl_syntax:atom(ok), erl_syntax:integer(42)]),
    [{op_return_value, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_return_value]),
    [Tag, Val] = erl_syntax:tuple_elements(Mutated),
    ?assertEqual(error, erl_syntax:atom_value(Tag)),
    ?assertEqual(42, erl_syntax:integer_value(Val)).

return_error_tuple_test() ->
    Node = erl_syntax:tuple([erl_syntax:atom(error), erl_syntax:atom(reason)]),
    [{op_return_value, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_return_value]),
    [Tag, _] = erl_syntax:tuple_elements(Mutated),
    ?assertEqual(ok, erl_syntax:atom_value(Tag)).

return_other_atom_test() ->
    Node = erl_syntax:atom(hello),
    ?assertEqual([], rebar3_mutate_operators:mutate_node(Node, [op_return_value])).

%%====================================================================
%% Statement delete
%%====================================================================

statement_delete_application_test() ->
    Node = erl_syntax:application(erl_syntax:atom(foo), [erl_syntax:integer(1)]),
    [{op_statement_delete, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [
        op_statement_delete
    ]),
    ?assertEqual(atom, erl_syntax:type(Mutated)),
    ?assertEqual(ok, erl_syntax:atom_value(Mutated)).

statement_delete_no_match_test() ->
    Node = erl_syntax:integer(42),
    ?assertEqual([], rebar3_mutate_operators:mutate_node(Node, [op_statement_delete])).

%%====================================================================
%% Constant
%%====================================================================

constant_integer_test() ->
    Node = erl_syntax:integer(5),
    Results = rebar3_mutate_operators:mutate_node(Node, [op_constant]),
    Values = [erl_syntax:integer_value(M) || {op_constant, M} <- Results],
    ?assert(lists:member(6, Values)),
    ?assert(lists:member(4, Values)),
    ?assert(lists:member(0, Values)).

constant_zero_test() ->
    Node = erl_syntax:integer(0),
    Results = rebar3_mutate_operators:mutate_node(Node, [op_constant]),
    Values = [erl_syntax:integer_value(M) || {op_constant, M} <- Results],
    ?assert(lists:member(1, Values)),
    ?assert(lists:member(-1, Values)),
    ?assertNot(lists:member(0, Values)).

constant_no_match_test() ->
    Node = erl_syntax:atom(hello),
    ?assertEqual([], rebar3_mutate_operators:mutate_node(Node, [op_constant])).

%%====================================================================
%% Negate condition
%%====================================================================

negate_condition_andalso_test() ->
    Node = make_infix(erl_syntax:atom(true), 'andalso', erl_syntax:atom(false)),
    [{op_negate_condition, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [
        op_negate_condition
    ]),
    ?assertEqual(prefix_expr, erl_syntax:type(Mutated)),
    ?assertEqual('not', erl_syntax:operator_name(erl_syntax:prefix_expr_operator(Mutated))).

negate_condition_not_removal_test() ->
    Inner = erl_syntax:atom(true),
    Node = erl_syntax:prefix_expr(erl_syntax:operator('not'), Inner),
    [{op_negate_condition, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [
        op_negate_condition
    ]),
    ?assertEqual(atom, erl_syntax:type(Mutated)),
    ?assertEqual(true, erl_syntax:atom_value(Mutated)).

negate_condition_no_match_test() ->
    Node = erl_syntax:integer(42),
    ?assertEqual([], rebar3_mutate_operators:mutate_node(Node, [op_negate_condition])).

%%====================================================================
%% List
%%====================================================================

list_concat_test() ->
    Node = make_infix(erl_syntax:list([]), '++', erl_syntax:list([])),
    [{op_list, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_list]),
    ?assertEqual('--', get_op(Mutated)).

list_subtract_test() ->
    Node = make_infix(erl_syntax:list([]), '--', erl_syntax:list([])),
    [{op_list, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_list]),
    ?assertEqual('++', get_op(Mutated)).

list_hd_to_tl_test() ->
    Node = erl_syntax:application(erl_syntax:atom(hd), [erl_syntax:list([erl_syntax:integer(1)])]),
    [{op_list, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_list]),
    ?assertEqual(application, erl_syntax:type(Mutated)),
    ?assertEqual(tl, erl_syntax:atom_value(erl_syntax:application_operator(Mutated))).

list_tl_to_hd_test() ->
    Node = erl_syntax:application(erl_syntax:atom(tl), [erl_syntax:list([erl_syntax:integer(1)])]),
    [{op_list, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_list]),
    ?assertEqual(application, erl_syntax:type(Mutated)),
    ?assertEqual(hd, erl_syntax:atom_value(erl_syntax:application_operator(Mutated))).

list_no_match_test() ->
    Node = erl_syntax:integer(42),
    ?assertEqual([], rebar3_mutate_operators:mutate_node(Node, [op_list])).

%%====================================================================
%% Multiple operators
%%====================================================================

multiple_operators_test() ->
    Node = make_infix(erl_syntax:integer(1), '+', erl_syntax:integer(2)),
    Results = rebar3_mutate_operators:mutate_node(Node, rebar3_mutate_operators:all()),
    OpTypes = [Op || {Op, _} <- Results],
    ?assert(lists:member(op_arithmetic, OpTypes)),
    ?assertNot(lists:member(op_relational, OpTypes)).

all_operators_count_test() ->
    ?assertEqual(14, length(rebar3_mutate_operators:all())).

%%====================================================================
%% Guard
%%====================================================================

guard_is_atom_test() ->
    Node = erl_syntax:application(erl_syntax:atom(is_atom), [erl_syntax:variable('X')]),
    [{op_guard, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_guard]),
    ?assertEqual(atom, erl_syntax:type(Mutated)),
    ?assertEqual(true, erl_syntax:atom_value(Mutated)).

guard_is_integer_test() ->
    Node = erl_syntax:application(erl_syntax:atom(is_integer), [erl_syntax:variable('X')]),
    [{op_guard, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_guard]),
    ?assertEqual(true, erl_syntax:atom_value(Mutated)).

guard_non_bif_test() ->
    Node = erl_syntax:application(erl_syntax:atom(my_fun), [erl_syntax:variable('X')]),
    ?assertEqual([], rebar3_mutate_operators:mutate_node(Node, [op_guard])).

%%====================================================================
%% Exception
%%====================================================================

exception_throw_to_error_test() ->
    Node = erl_syntax:application(erl_syntax:atom(throw), [erl_syntax:atom(reason)]),
    [{op_exception, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_exception]),
    ?assertEqual(error, erl_syntax:atom_value(erl_syntax:application_operator(Mutated))).

exception_error_to_throw_test() ->
    Node = erl_syntax:application(erl_syntax:atom(error), [erl_syntax:atom(reason)]),
    [{op_exception, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_exception]),
    ?assertEqual(throw, erl_syntax:atom_value(erl_syntax:application_operator(Mutated))).

exception_exit_to_throw_test() ->
    Node = erl_syntax:application(erl_syntax:atom(exit), [erl_syntax:atom(reason)]),
    [{op_exception, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_exception]),
    ?assertEqual(throw, erl_syntax:atom_value(erl_syntax:application_operator(Mutated))).

exception_wrong_arity_test() ->
    Node = erl_syntax:application(erl_syntax:atom(throw), [
        erl_syntax:atom(reason), erl_syntax:atom(extra)
    ]),
    ?assertEqual([], rebar3_mutate_operators:mutate_node(Node, [op_exception])).

%%====================================================================
%% Map
%%====================================================================

map_remove_field_test() ->
    F1 = erl_syntax:map_field_assoc(erl_syntax:atom(a), erl_syntax:integer(1)),
    F2 = erl_syntax:map_field_assoc(erl_syntax:atom(b), erl_syntax:integer(2)),
    Node = erl_syntax:map_expr([F1, F2]),
    [{op_map, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_map]),
    ?assertEqual(map_expr, erl_syntax:type(Mutated)),
    ?assertEqual(1, length(erl_syntax:map_expr_fields(Mutated))).

map_single_field_no_mutation_test() ->
    F1 = erl_syntax:map_field_assoc(erl_syntax:atom(a), erl_syntax:integer(1)),
    Node = erl_syntax:map_expr([F1]),
    ?assertEqual([], rebar3_mutate_operators:mutate_node(Node, [op_map])).

%%====================================================================
%% Binary
%%====================================================================

binary_no_size_test() ->
    Node = erl_syntax:binary([
        erl_syntax:binary_field(erl_syntax:variable('X'))
    ]),
    ?assertEqual([], rebar3_mutate_operators:mutate_node(Node, [op_binary])).

%%====================================================================
%% Clause swap
%%====================================================================

clause_swap_case_test() ->
    C1 = erl_syntax:clause([erl_syntax:atom(a)], none, [erl_syntax:atom(one)]),
    C2 = erl_syntax:clause([erl_syntax:atom(b)], none, [erl_syntax:atom(two)]),
    Node = erl_syntax:case_expr(erl_syntax:variable('X'), [C1, C2]),
    [{op_clause_swap, Mutated}] = rebar3_mutate_operators:mutate_node(Node, [op_clause_swap]),
    ?assertEqual(case_expr, erl_syntax:type(Mutated)),
    [MC1, MC2] = erl_syntax:case_expr_clauses(Mutated),
    %% First clause should now be C2 (pattern 'b')
    [P1] = erl_syntax:clause_patterns(MC1),
    ?assertEqual(b, erl_syntax:atom_value(P1)),
    [P2] = erl_syntax:clause_patterns(MC2),
    ?assertEqual(a, erl_syntax:atom_value(P2)).

clause_swap_single_clause_test() ->
    C1 = erl_syntax:clause([erl_syntax:atom(a)], none, [erl_syntax:atom(one)]),
    Node = erl_syntax:case_expr(erl_syntax:variable('X'), [C1]),
    ?assertEqual([], rebar3_mutate_operators:mutate_node(Node, [op_clause_swap])).

clause_swap_non_case_test() ->
    Node = erl_syntax:integer(42),
    ?assertEqual([], rebar3_mutate_operators:mutate_node(Node, [op_clause_swap])).

%%====================================================================
%% Receive
%%====================================================================

receive_no_timeout_test() ->
    C1 = erl_syntax:clause([erl_syntax:atom(msg)], none, [erl_syntax:atom(ok)]),
    Node = erl_syntax:receive_expr([C1]),
    ?assertEqual([], rebar3_mutate_operators:mutate_node(Node, [op_receive])).

%%====================================================================
%% Helpers
%%====================================================================

make_infix(Left, Op, Right) ->
    erl_syntax:infix_expr(Left, erl_syntax:operator(Op), Right).

get_op(InfixNode) ->
    erl_syntax:operator_name(erl_syntax:infix_expr_operator(InfixNode)).
