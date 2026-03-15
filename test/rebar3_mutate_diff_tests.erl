-module(rebar3_mutate_diff_tests).

-include_lib("eunit/include/eunit.hrl").

parse_single_hunk_test() ->
    Diff =
        "diff --git a/src/foo.erl b/src/foo.erl\n"
        "--- a/src/foo.erl\n"
        "+++ b/src/foo.erl\n"
        "@@ -10,3 +10,5 @@ some context\n"
        "+new line 1\n"
        "+new line 2\n",
    Result = rebar3_mutate_diff:parse_diff(Diff),
    ?assert(maps:is_key("src/foo.erl", Result)),
    ?assertEqual([10, 11, 12, 13, 14], maps:get("src/foo.erl", Result)).

parse_multiple_hunks_test() ->
    Diff =
        "diff --git a/src/bar.erl b/src/bar.erl\n"
        "--- a/src/bar.erl\n"
        "+++ b/src/bar.erl\n"
        "@@ -5,2 +5,3 @@ context\n"
        "+added\n"
        "@@ -20,1 +21,2 @@ more context\n"
        "+another\n",
    Result = rebar3_mutate_diff:parse_diff(Diff),
    Lines = maps:get("src/bar.erl", Result),
    ?assert(lists:member(5, Lines)),
    ?assert(lists:member(6, Lines)),
    ?assert(lists:member(7, Lines)),
    ?assert(lists:member(21, Lines)),
    ?assert(lists:member(22, Lines)).

parse_multiple_files_test() ->
    Diff =
        "diff --git a/src/a.erl b/src/a.erl\n"
        "--- a/src/a.erl\n"
        "+++ b/src/a.erl\n"
        "@@ -1,1 +1,2 @@\n"
        "+new\n"
        "diff --git a/src/b.erl b/src/b.erl\n"
        "--- a/src/b.erl\n"
        "+++ b/src/b.erl\n"
        "@@ -10,1 +10,1 @@\n"
        "-old\n"
        "+new\n",
    Result = rebar3_mutate_diff:parse_diff(Diff),
    ?assert(maps:is_key("src/a.erl", Result)),
    ?assert(maps:is_key("src/b.erl", Result)),
    ?assertEqual([1, 2], maps:get("src/a.erl", Result)),
    ?assertEqual([10], maps:get("src/b.erl", Result)).

parse_single_line_hunk_test() ->
    Diff =
        "diff --git a/src/c.erl b/src/c.erl\n"
        "--- a/src/c.erl\n"
        "+++ b/src/c.erl\n"
        "@@ -5 +5 @@\n"
        "-old\n"
        "+new\n",
    Result = rebar3_mutate_diff:parse_diff(Diff),
    ?assertEqual([5], maps:get("src/c.erl", Result)).

parse_empty_diff_test() ->
    Result = rebar3_mutate_diff:parse_diff(""),
    ?assertEqual(#{}, Result).

parse_new_file_test() ->
    Diff =
        "diff --git a/src/new.erl b/src/new.erl\n"
        "--- /dev/null\n"
        "+++ b/src/new.erl\n"
        "@@ -0,0 +1,5 @@\n"
        "+line1\n"
        "+line2\n",
    Result = rebar3_mutate_diff:parse_diff(Diff),
    ?assert(maps:is_key("src/new.erl", Result)),
    ?assertEqual([1, 2, 3, 4, 5], maps:get("src/new.erl", Result)).
