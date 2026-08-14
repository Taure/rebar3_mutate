-module(rebar3_mutate_diff).

-export([changed_lines/1, parse_diff/1, valid_ref/1, matches_path/2]).

-type line_range() :: {non_neg_integer(), non_neg_integer()}.
-type file_changes() :: #{file:filename() => [line_range()]}.
-export_type([file_changes/0, line_range/0]).

%% Changed files and line ranges between a base ref and HEAD, as a map of
%% repo-relative filename => [{StartLine, EndLine}] over the new version.
-spec changed_lines(string()) -> {ok, file_changes()} | {error, term()}.
changed_lines(BaseRef) ->
    case valid_ref(BaseRef) of
        false ->
            {error, {invalid_base_ref, BaseRef}};
        true ->
            case git(["rev-parse", "--verify", "--quiet", BaseRef ++ "^{commit}"]) of
                {ok, _} -> diff(BaseRef);
                {error, _} -> {error, {unreachable_base_ref, BaseRef}}
            end
    end.

%% The ref is passed to git as a single argv entry, so it can never be split
%% into extra arguments, but git still reads a leading dash as an option.
-spec valid_ref(string()) -> boolean().
valid_ref([]) -> false;
valid_ref([$- | _]) -> false;
valid_ref(Ref) -> not lists:any(fun(Char) -> Char =< 32 end, Ref).

-spec matches_path(file:filename(), file:filename()) -> boolean().
matches_path(File, DiffPath) ->
    File =:= DiffPath orelse lists:suffix("/" ++ DiffPath, File).

%%====================================================================
%% Internal
%%====================================================================

diff(BaseRef) ->
    Args = [
        "-c",
        "core.quotePath=false",
        "diff",
        "--unified=0",
        "--no-prefix",
        BaseRef ++ "...HEAD"
    ],
    case git(Args) of
        {ok, Output} -> {ok, parse_diff(Output)};
        {error, _} = Err -> Err
    end.

git(Args) ->
    case os:find_executable("git") of
        false ->
            {error, git_not_found};
        Git ->
            Port = open_port(
                {spawn_executable, Git},
                [exit_status, use_stdio, binary, stderr_to_stdout, {args, Args}]
            ),
            collect_port(Port, [])
    end.

collect_port(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_port(Port, [Data | Acc]);
        {Port, {exit_status, 0}} ->
            {ok, iolist_to_binary(lists:reverse(Acc))};
        {Port, {exit_status, Code}} ->
            {error, {git_exit, Code, iolist_to_binary(lists:reverse(Acc))}}
    after 30000 ->
        port_close(Port),
        {error, timeout}
    end.

%% "+++ " is only a file header between "diff --git" and the first hunk. Inside
%% a hunk it is an added line whose content starts with "++ ", so the parser
%% has to be stateful rather than matching the prefix anywhere.
parse_diff(Output) ->
    Lines = binary:split(Output, <<"\n">>, [global]),
    parse_lines(Lines, header, undefined, #{}).

parse_lines([], _State, _File, Acc) ->
    Acc;
parse_lines([<<"diff --git ", _/binary>> | Rest], _State, _File, Acc) ->
    parse_lines(Rest, header, undefined, Acc);
parse_lines([<<"+++ /dev/null">> | Rest], header, _File, Acc) ->
    parse_lines(Rest, header, undefined, Acc);
parse_lines([<<"+++ ", Path/binary>> | Rest], header, _File, Acc) ->
    parse_lines(Rest, hunks, string:trim(binary_to_list(Path)), Acc);
parse_lines([<<"@@ ", Hunk/binary>> | Rest], hunks, File, Acc) when File =/= undefined ->
    case parse_hunk_header(Hunk) of
        {ok, _Start, 0} ->
            parse_lines(Rest, hunks, File, Acc);
        {ok, Start, Count} ->
            Ranges = maps:get(File, Acc, []),
            End = Start + Count - 1,
            parse_lines(Rest, hunks, File, Acc#{File => [{Start, End} | Ranges]});
        error ->
            parse_lines(Rest, hunks, File, Acc)
    end;
parse_lines([_ | Rest], State, File, Acc) ->
    parse_lines(Rest, State, File, Acc).

%% Parse the +start,count portion from "@@ -X,Y +Start,Count @@"
parse_hunk_header(Hunk) ->
    case re:run(Hunk, <<"\\+([0-9]+)(?:,([0-9]+))?">>, [{capture, all_but_first, list}]) of
        {match, [StartStr, CountStr]} ->
            {ok, list_to_integer(StartStr), list_to_integer(CountStr)};
        {match, [StartStr]} ->
            {ok, list_to_integer(StartStr), 1};
        nomatch ->
            error
    end.
