-module(rebar3_mutate_ast).

-export([
    parse_file/2,
    mutation_points/2,
    apply_mutation/2,
    describe_mutation/1,
    get_point_line/1,
    get_point_file/1,
    get_point_operator/1
]).

-type path_step() :: {pos_integer(), pos_integer()}.

-record(mutation_point, {
    path :: [path_step()],
    operator :: rebar3_mutate_operators:operator(),
    file :: file:filename(),
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

%% Mutation points are identified by their child-index path from the root of
%% the form list, so applying one is a splice rather than a second traversal
%% that has to re-derive the same index.
-spec mutation_points([erl_parse:abstract_form()], [rebar3_mutate_operators:operator()]) ->
    [mutation_point()].
mutation_points(Forms, Operators) ->
    Source = source_file(Forms),
    Mutable = mutable_forms(tree_forms(Forms), Source),
    lists:append([
        collect(Form, [{1, Index}], Source, 0, Operators)
     || {Index, Form} <- Mutable
    ]).

-spec apply_mutation([erl_parse:abstract_form()], mutation_point()) ->
    [erl_parse:abstract_form()].
apply_mutation(Forms, #mutation_point{path = Path, mutated = Mutated}) ->
    Tree = erl_syntax:form_list(tree_forms(Forms)),
    erl_syntax:revert_forms(splice(Tree, Path, Mutated)).

-spec describe_mutation(mutation_point()) -> iolist().
describe_mutation(#mutation_point{operator = Op, line = Line, original = Orig, mutated = Mut}) ->
    io_lib:format("line ~B [~s] ~s -> ~s", [Line, Op, render(Orig), render(Mut)]).

-spec get_point_line(mutation_point()) -> non_neg_integer().
get_point_line(#mutation_point{line = Line}) -> Line.

-spec get_point_file(mutation_point()) -> file:filename().
get_point_file(#mutation_point{file = File}) -> File.

-spec get_point_operator(mutation_point()) -> rebar3_mutate_operators:operator().
get_point_operator(#mutation_point{operator = Op}) -> Op.

%%====================================================================
%% Traversal
%%====================================================================

collect(Node, Path, Source, ParentLine, Operators) ->
    Line = node_line(Node, ParentLine),
    Children = lists:append([
        collect(Child, Path ++ [{GroupIndex, ChildIndex}], Source, Line, Operators)
     || {GroupIndex, Group} <- lists:enumerate(erl_syntax:subtrees(Node)),
        {ChildIndex, Child} <- lists:enumerate(Group)
    ]),
    Own = [
        #mutation_point{
            path = Path,
            operator = Op,
            file = Source,
            line = Line,
            original = Node,
            mutated = Mutated
        }
     || {Op, Mutated} <- rebar3_mutate_operators:mutate_node(Node, Operators)
    ],
    Children ++ Own.

splice(_Node, [], New) ->
    New;
splice(Node, [{GroupIndex, ChildIndex} | Rest], New) ->
    Groups = erl_syntax:subtrees(Node),
    Group = lists:nth(GroupIndex, Groups),
    Child = lists:nth(ChildIndex, Group),
    NewGroup = set_nth(ChildIndex, Group, splice(Child, Rest, New)),
    erl_syntax:update_tree(Node, set_nth(GroupIndex, Groups, NewGroup)).

%%====================================================================
%% Form selection
%%====================================================================

%% Only function bodies defined in the module's own source are mutable.
%% Attributes carry no runtime behaviour, so mutating a -spec type atom or an
%% -export arity yields a mutant that is either inert or a guaranteed compile
%% error. Test functions are excluded because parse_file/2 defines TEST.
mutable_forms(Forms, Source) ->
    mutable_forms(Forms, 1, Source, Source, []).

mutable_forms([], _Index, _Source, _Current, Acc) ->
    lists:reverse(Acc);
mutable_forms([{attribute, _, file, {File, _}} | Rest], Index, Source, _Current, Acc) ->
    mutable_forms(Rest, Index + 1, Source, File, Acc);
mutable_forms([{function, _, Name, Arity, _} = Form | Rest], Index, Source, Current, Acc) ->
    case Current =:= Source andalso not is_test_function(Name, Arity) of
        true -> mutable_forms(Rest, Index + 1, Source, Current, [{Index, Form} | Acc]);
        false -> mutable_forms(Rest, Index + 1, Source, Current, Acc)
    end;
mutable_forms([_ | Rest], Index, Source, Current, Acc) ->
    mutable_forms(Rest, Index + 1, Source, Current, Acc).

is_test_function(Name, 0) ->
    lists:suffix("_test", atom_to_list(Name)) orelse
        lists:suffix("_test_", atom_to_list(Name));
is_test_function(_Name, _Arity) ->
    false.

%%====================================================================
%% Internal
%%====================================================================

tree_forms(Forms) ->
    [F || F <- Forms, not is_eqwalizer(F)].

is_eqwalizer({attribute, _, eqwalizer, _}) -> true;
is_eqwalizer(_) -> false.

extract_module([{attribute, _, module, Mod} | _]) -> Mod;
extract_module([_ | Rest]) -> extract_module(Rest);
extract_module([]) -> undefined.

source_file([{attribute, _, file, {File, _}} | _]) -> File;
source_file([_ | Rest]) -> source_file(Rest);
source_file([]) -> "".

%% Positions are missing on nodes erl_syntax synthesises from attribute
%% payloads; inheriting the enclosing node's line keeps every point locatable.
node_line(Node, ParentLine) ->
    try erl_anno:line(erl_syntax:get_pos(Node)) of
        0 -> ParentLine;
        Line -> Line
    catch
        _:_ -> ParentLine
    end.

render(Node) ->
    try
        erl_prettypr:format(Node, [{paper, 80}, {ribbon, 60}])
    catch
        _:_ -> "?"
    end.

set_nth(1, [_ | Rest], Value) -> [Value | Rest];
set_nth(N, [Head | Rest], Value) -> [Head | set_nth(N - 1, Rest, Value)].
