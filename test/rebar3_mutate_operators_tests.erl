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
    Node = erl_syntax:integer(42),
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

relational_no_match_test() ->
    Node = make_infix(erl_syntax:integer(1), '+', erl_syntax:integer(2)),
    ?assertEqual([], rebar3_mutate_operators:mutate_node(Node, [op_relational])).

%%====================================================================
%% Boolean
%%====================================================================

boolean_andalso_test() ->
    Node = make_infix(erl_syntax:atom(true), 'andalso', erl_syntax:atom(false)),
    Results = rebar3_mutate_operators:mutate_node(Node, [op_boolean]),
    %% andalso -> orelse, plus true->false and false->true on the children
    OpNames = [Op || {Op, _} <- Results],
    ?assert(lists:member(op_boolean, OpNames)),
    %% The infix mutation should be andalso -> orelse
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
%% Multiple operators
%%====================================================================

multiple_operators_test() ->
    %% A '+' node should match arithmetic but not relational
    Node = make_infix(erl_syntax:integer(1), '+', erl_syntax:integer(2)),
    Results = rebar3_mutate_operators:mutate_node(Node, rebar3_mutate_operators:all()),
    OpTypes = [Op || {Op, _} <- Results],
    ?assert(lists:member(op_arithmetic, OpTypes)),
    ?assertNot(lists:member(op_relational, OpTypes)).

%%====================================================================
%% Helpers
%%====================================================================

make_infix(Left, Op, Right) ->
    erl_syntax:infix_expr(Left, erl_syntax:operator(Op), Right).

get_op(InfixNode) ->
    erl_syntax:operator_name(erl_syntax:infix_expr_operator(InfixNode)).
