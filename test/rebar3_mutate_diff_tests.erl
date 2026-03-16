-module(rebar3_mutate_diff_tests).

-include_lib("eunit/include/eunit.hrl").

parse_hunk_single_line_test() ->
    Output = <<
        "diff --git a/src/foo.erl b/src/foo.erl\n"
        "--- a/src/foo.erl\n"
        "+++ b/src/foo.erl\n"
        "@@ -10,0 +11 @@\n"
        "+new_line().\n"
    >>,
    Result = rebar3_mutate_diff:parse_diff(Output),
    ?assertMatch(#{"src/foo.erl" := [{11, 11}]}, Result).

parse_hunk_multi_line_test() ->
    Output = <<
        "diff --git a/src/foo.erl b/src/foo.erl\n"
        "--- a/src/foo.erl\n"
        "+++ b/src/foo.erl\n"
        "@@ -5,3 +5,5 @@\n"
        " context\n"
        "+added1\n"
        "+added2\n"
    >>,
    Result = rebar3_mutate_diff:parse_diff(Output),
    ?assertMatch(#{"src/foo.erl" := [{5, 9}]}, Result).

parse_multiple_hunks_test() ->
    Output = <<
        "diff --git a/src/foo.erl b/src/foo.erl\n"
        "--- a/src/foo.erl\n"
        "+++ b/src/foo.erl\n"
        "@@ -5,0 +5,2 @@\n"
        "+line1\n"
        "+line2\n"
        "@@ -20,0 +22 @@\n"
        "+line3\n"
    >>,
    Result = rebar3_mutate_diff:parse_diff(Output),
    Ranges = maps:get("src/foo.erl", Result),
    ?assertEqual(2, length(Ranges)),
    ?assert(lists:member({5, 6}, Ranges)),
    ?assert(lists:member({22, 22}, Ranges)).

parse_multiple_files_test() ->
    Output = <<
        "diff --git a/src/foo.erl b/src/foo.erl\n"
        "--- a/src/foo.erl\n"
        "+++ b/src/foo.erl\n"
        "@@ -1,0 +1 @@\n"
        "+new\n"
        "diff --git a/src/bar.erl b/src/bar.erl\n"
        "--- a/src/bar.erl\n"
        "+++ b/src/bar.erl\n"
        "@@ -10,2 +10,3 @@\n"
        " ctx\n"
        "+added\n"
    >>,
    Result = rebar3_mutate_diff:parse_diff(Output),
    ?assert(maps:is_key("src/foo.erl", Result)),
    ?assert(maps:is_key("src/bar.erl", Result)).

parse_empty_diff_test() ->
    Result = rebar3_mutate_diff:parse_diff(<<>>),
    ?assertEqual(#{}, Result).

parse_new_file_test() ->
    Output = <<
        "diff --git a/src/new.erl b/src/new.erl\n"
        "new file mode 100644\n"
        "--- /dev/null\n"
        "+++ b/src/new.erl\n"
        "@@ -0,0 +1,10 @@\n"
        "+line\n"
    >>,
    Result = rebar3_mutate_diff:parse_diff(Output),
    ?assertMatch(#{"src/new.erl" := [{1, 10}]}, Result).

parse_zero_count_hunk_test() ->
    %% @@ -X,Y +Z,0 @@ means deletion only — no new lines
    Output = <<
        "diff --git a/src/foo.erl b/src/foo.erl\n"
        "--- a/src/foo.erl\n"
        "+++ b/src/foo.erl\n"
        "@@ -5,3 +5,0 @@\n"
        "-removed\n"
    >>,
    Result = rebar3_mutate_diff:parse_diff(Output),
    Ranges = maps:get("src/foo.erl", Result),
    %% Count=0 means Start=5, End=5 (max(0-1,0) = 0, so End=5+0=5)
    ?assert(lists:member({5, 5}, Ranges)).
