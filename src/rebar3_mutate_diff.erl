-module(rebar3_mutate_diff).

-export([changed_lines/1, parse_diff/1]).

-spec changed_lines(string()) -> #{file:filename() => [pos_integer()]}.
changed_lines(BaseBranch) ->
    Cmd = "git diff --unified=0 " ++ BaseBranch ++ "...HEAD -- '*.erl'",
    Output = os:cmd(Cmd),
    parse_diff(Output).

-spec parse_diff(string()) -> #{file:filename() => [pos_integer()]}.
parse_diff(Output) ->
    Lines = string:split(Output, "\n", all),
    parse_lines(Lines, undefined, #{}).

%%====================================================================
%% Internal
%%====================================================================

parse_lines([], _CurrentFile, Acc) ->
    Acc;
parse_lines(["--- " ++ _ | Rest], CurrentFile, Acc) ->
    parse_lines(Rest, CurrentFile, Acc);
parse_lines(["+++ b/" ++ File | Rest], _CurrentFile, Acc) ->
    parse_lines(Rest, string:trim(File), Acc);
parse_lines(["@@ " ++ Hunk | Rest], CurrentFile, Acc) when CurrentFile =/= undefined ->
    case parse_hunk_header(Hunk) of
        {ok, Start, Count} ->
            LineNums = lists:seq(Start, Start + Count - 1),
            Existing = maps:get(CurrentFile, Acc, []),
            parse_lines(Rest, CurrentFile, Acc#{CurrentFile => Existing ++ LineNums});
        error ->
            parse_lines(Rest, CurrentFile, Acc)
    end;
parse_lines([_ | Rest], CurrentFile, Acc) ->
    parse_lines(Rest, CurrentFile, Acc).

parse_hunk_header(Hunk) ->
    %% Format: "-old,count +new,count @@" or "-old +new,count @@"
    case re:run(Hunk, "\\+([0-9]+)(?:,([0-9]+))?", [{capture, all_but_first, list}]) of
        {match, [StartStr, CountStr]} ->
            {ok, list_to_integer(StartStr), max(1, list_to_integer(CountStr))};
        {match, [StartStr]} ->
            {ok, list_to_integer(StartStr), 1};
        nomatch ->
            error
    end.
