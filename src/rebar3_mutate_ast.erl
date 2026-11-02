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
-type forms() :: [erl_parse:abstract_form() | {eof, erl_anno:location()}].
-export_type([mutation_point/0, forms/0]).

%% EppOpts comes from rebar3_mutate_opts:epp/2 so the module is parsed the way
%% the project builds it. epp answers {ok, Forms} even when it could not resolve
%% an include or a macro, embedding {error, _} forms and dropping the functions
%% around them, so a parse that lost anything is rejected rather than scored.
-spec parse_file(file:filename(), [rebar3_mutate_opts:epp_option()]) ->
    {ok, atom(), forms()} | {error, term()}.
parse_file(File, EppOpts) ->
    case epp:parse_file(File, EppOpts) of
        {ok, Parsed} ->
            case split_errors(Parsed) of
                {Forms, []} -> {ok, extract_module(Forms), Forms};
                {_Forms, Errors} -> {error, {incomplete_parse, Errors}}
            end;
        {error, _} = Err ->
            Err
    end.

%% Mutation points are identified by their child-index path from the root of
%% the form list, so applying one is a splice rather than a second traversal
%% that has to re-derive the same index.
-spec mutation_points(forms(), [rebar3_mutate_operators:operator()]) ->
    [mutation_point()].
mutation_points(Forms, Operators) ->
    Source = source_file(Forms),
    Mutable = mutable_forms(tree_forms(Forms), Source),
    lists:append([
        collect(Form, [{1, Index}], Source, 0, Operators)
     || {Index, Form} <- Mutable
    ]).

-spec apply_mutation(forms(), mutation_point()) -> forms().
apply_mutation(Forms, #mutation_point{path = Path, mutated = Mutated}) ->
    Tree = erl_syntax:form_list(tree_forms(Forms)),
    revert_forms(splice(Tree, Path, Mutated)).

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
    case logger_macro_arguments(Node) of
        {ok, Arguments} ->
            Line = node_line(Node, ParentLine),
            lists:append([
                collect(Argument, Path ++ RelativePath, Source, Line, Operators)
             || {RelativePath, Argument} <- Arguments
            ]);
        false ->
            collect_node(Node, Path, Source, ParentLine, Operators)
    end.

collect_node(Node, Path, Source, ParentLine, Operators) ->
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

%% ?LOG_*/?LOG from logger.hrl expand, on every OTP release from 24 on, to
%%
%%     case logger:allow(Level, ?MODULE) of
%%         true -> erlang:apply(logger, macro_log, [?LOCATION, Level | Args]);
%%         false -> ok
%%     end
%%
%% The scaffolding's constants are the call site's line, level and location,
%% which no test can tell apart, so only what the caller wrote is collected:
%% each of Args, and Level where it is an expression rather than an atom. The
%% paths are child-index steps from the case node, as splice/3 follows them.
-spec logger_macro_arguments(erl_syntax:syntaxTree()) ->
    {ok, [{[path_step()], erl_syntax:syntaxTree()}]} | false.
logger_macro_arguments(Node) ->
    case erl_syntax:type(Node) of
        case_expr ->
            case erl_syntax:subtrees(Node) of
                [[Allow], [True, False]] ->
                    case {allow_level(Allow), macro_log_arguments(True), is_false_ok(False)} of
                        {{ok, Level}, {ok, Arguments}, true} ->
                            {ok,
                                [{[{1, 1} | Steps], Part} || {Steps, Part} <- Level] ++
                                    [{[{2, 1} | Steps], Part} || {Steps, Part} <- Arguments]};
                        _ ->
                            false
                    end;
                _ ->
                    false
            end;
        _ ->
            false
    end.

allow_level(Allow) ->
    case {call_target(Allow), erl_syntax:subtrees(Allow)} of
        {{logger, allow, 2}, [[_Operator], [Level, _Module]]} ->
            case erl_syntax:type(Level) of
                atom -> {ok, []};
                _ -> {ok, [{[{2, 1}], Level}]}
            end;
        _ ->
            false
    end.

macro_log_arguments(Clause) ->
    case {clause_atom(Clause), erl_syntax:subtrees(Clause)} of
        {true, [[_Pattern], [Body]]} ->
            case {call_target(Body), erl_syntax:subtrees(Body)} of
                {{erlang, apply, 3}, [[_Operator], [Module, Function, Arguments]]} ->
                    case {atom_value(Module), atom_value(Function)} of
                        {logger, macro_log} -> user_arguments(Arguments);
                        _ -> false
                    end;
                _ ->
                    false
            end;
        _ ->
            false
    end.

%% [?LOCATION, Level | Args]: the first two elements are the macro's own.
user_arguments(List) ->
    case {erl_syntax:type(List), erl_syntax:subtrees(List)} of
        {list, [[_Location, _Level | Arguments]]} ->
            {ok, [
                {[{2, 1}, {2, 3}, {1, Index}], Argument}
             || {Index, Argument} <- lists:enumerate(3, Arguments)
            ]};
        _ ->
            false
    end.

is_false_ok(Clause) ->
    case {clause_atom(Clause), erl_syntax:clause_body(Clause)} of
        {false, [Body]} -> atom_value(Body) =:= ok;
        _ -> false
    end.

clause_atom(Clause) ->
    case {erl_syntax:clause_patterns(Clause), erl_syntax:clause_guard(Clause)} of
        {[Pattern], none} -> atom_value(Pattern);
        _ -> none
    end.

call_target(Node) ->
    case erl_syntax:type(Node) of
        application ->
            Arity = length(erl_syntax:application_arguments(Node)),
            Operator = erl_syntax:application_operator(Node),
            case erl_syntax:type(Operator) of
                module_qualifier ->
                    {
                        atom_value(erl_syntax:module_qualifier_argument(Operator)),
                        atom_value(erl_syntax:module_qualifier_body(Operator)),
                        Arity
                    };
                _ ->
                    none
            end;
        _ ->
            none
    end.

atom_value(Node) ->
    case erl_syntax:type(Node) of
        atom -> erl_syntax:atom_value(Node);
        _ -> none
    end.

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

-spec split_errors([erl_parse:abstract_form() | {eof, erl_anno:location()} | {error, term()}]) ->
    {forms(), [term()]}.
split_errors([{error, Reason} | Rest]) ->
    {Forms, Errors} = split_errors(Rest),
    {Forms, [Reason | Errors]};
split_errors([Form | Rest]) ->
    {Forms, Errors} = split_errors(Rest),
    {[Form | Forms], Errors};
split_errors([]) ->
    {[], []}.

-spec revert_forms(erl_syntax:syntaxTree()) -> dynamic().
revert_forms(Tree) ->
    erl_syntax:revert_forms(Tree).

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
