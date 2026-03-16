-module(rebar3_mutate_diff).

-export([changed_lines/1, parse_diff/1]).

-type line_range() :: {non_neg_integer(), non_neg_integer()}.
-type file_changes() :: #{file:filename() => [line_range()]}.
-export_type([file_changes/0, line_range/0]).

%% Parse `git diff <base>...HEAD` to extract changed files and line ranges.
%% Returns a map of filename => list of {StartLine, EndLine} tuples
%% representing added/modified lines in the new version.
-spec changed_lines(string()) -> {ok, file_changes()} | {error, term()}.
changed_lines(BaseRef) ->
    Cmd = "git diff --unified=0 " ++ BaseRef ++ "...HEAD",
    case run_git(Cmd) of
        {ok, Output} ->
            {ok, parse_diff(Output)};
        {error, _} = Err ->
            Err
    end.

%%====================================================================
%% Internal
%%====================================================================

run_git(Cmd) ->
    Port = open_port(
        {spawn, Cmd},
        [exit_status, use_stdio, binary, stderr_to_stdout]
    ),
    collect_port(Port, []).

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

parse_diff(Output) ->
    Lines = binary:split(Output, <<"\n">>, [global]),
    parse_lines(Lines, undefined, #{}).

parse_lines([], _CurrentFile, Acc) ->
    Acc;
parse_lines([<<"diff --git ", _/binary>> | Rest], _CurrentFile, Acc) ->
    parse_lines(Rest, undefined, Acc);
parse_lines([<<"+++ b/", Path/binary>> | Rest], _CurrentFile, Acc) ->
    File = string:trim(binary_to_list(Path)),
    parse_lines(Rest, File, Acc);
parse_lines([<<"@@ ", Hunk/binary>> | Rest], CurrentFile, Acc) when CurrentFile =/= undefined ->
    case parse_hunk_header(Hunk) of
        {ok, Start, Count} ->
            End = Start + max(Count - 1, 0),
            Ranges = maps:get(CurrentFile, Acc, []),
            parse_lines(Rest, CurrentFile, Acc#{CurrentFile => [{Start, End} | Ranges]});
        error ->
            parse_lines(Rest, CurrentFile, Acc)
    end;
parse_lines([_ | Rest], CurrentFile, Acc) ->
    parse_lines(Rest, CurrentFile, Acc).

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
