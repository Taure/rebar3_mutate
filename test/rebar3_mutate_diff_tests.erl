-module(rebar3_mutate_diff_tests).

-include_lib("eunit/include/eunit.hrl").

parse_hunk_single_line_test() ->
    Output = <<
        "diff --git src/foo.erl src/foo.erl\n"
        "--- src/foo.erl\n"
        "+++ src/foo.erl\n"
        "@@ -10,0 +11 @@\n"
        "+new_line().\n"
    >>,
    Result = rebar3_mutate_diff:parse_diff(Output),
    ?assertMatch(#{"src/foo.erl" := [{11, 11}]}, Result).

parse_hunk_multi_line_test() ->
    Output = <<
        "diff --git src/foo.erl src/foo.erl\n"
        "--- src/foo.erl\n"
        "+++ src/foo.erl\n"
        "@@ -5,3 +5,5 @@\n"
        " context\n"
        "+added1\n"
        "+added2\n"
    >>,
    Result = rebar3_mutate_diff:parse_diff(Output),
    ?assertMatch(#{"src/foo.erl" := [{5, 9}]}, Result).

parse_multiple_hunks_test() ->
    Output = <<
        "diff --git src/foo.erl src/foo.erl\n"
        "--- src/foo.erl\n"
        "+++ src/foo.erl\n"
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
        "diff --git src/foo.erl src/foo.erl\n"
        "--- src/foo.erl\n"
        "+++ src/foo.erl\n"
        "@@ -1,0 +1 @@\n"
        "+new\n"
        "diff --git src/bar.erl src/bar.erl\n"
        "--- src/bar.erl\n"
        "+++ src/bar.erl\n"
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
        "diff --git src/new.erl src/new.erl\n"
        "new file mode 100644\n"
        "--- /dev/null\n"
        "+++ src/new.erl\n"
        "@@ -0,0 +1,10 @@\n"
        "+line\n"
    >>,
    Result = rebar3_mutate_diff:parse_diff(Output),
    ?assertMatch(#{"src/new.erl" := [{1, 10}]}, Result).

%% "@@ -5,3 +5,0 @@" is a deletion: it contributes no lines to the new file, so
%% diff mode must not offer a range for it.
parse_zero_count_hunk_adds_nothing_test() ->
    Output = <<
        "diff --git src/foo.erl src/foo.erl\n"
        "--- src/foo.erl\n"
        "+++ src/foo.erl\n"
        "@@ -5,3 +5,0 @@\n"
        "-removed\n"
    >>,
    Result = rebar3_mutate_diff:parse_diff(Output),
    ?assertEqual([], maps:get("src/foo.erl", Result, [])).

parse_deleted_file_test() ->
    Output = <<
        "diff --git src/gone.erl src/gone.erl\n"
        "deleted file mode 100644\n"
        "--- src/gone.erl\n"
        "+++ /dev/null\n"
        "@@ -1,10 +0,0 @@\n"
        "-line\n"
    >>,
    ?assertEqual(#{}, rebar3_mutate_diff:parse_diff(Output)).

%% An added line whose content begins with "++ " renders as "+++ ", which the
%% old prefix-anywhere parser mistook for a file header.
added_line_looking_like_a_header_test() ->
    Output = <<
        "diff --git src/foo.erl src/foo.erl\n"
        "--- src/foo.erl\n"
        "+++ src/foo.erl\n"
        "@@ -1,0 +1 @@\n"
        "+++ not/a/header.erl\n"
    >>,
    Result = rebar3_mutate_diff:parse_diff(Output),
    ?assertEqual([<<"src/foo.erl">>], [list_to_binary(K) || K <- maps:keys(Result)]).

%%====================================================================
%% Base ref validation
%%====================================================================

valid_ref_accepts_normal_refs_test() ->
    ?assert(rebar3_mutate_diff:valid_ref("origin/main")),
    ?assert(rebar3_mutate_diff:valid_ref("HEAD~1")),
    ?assert(rebar3_mutate_diff:valid_ref("v1.2.3")),
    ?assert(rebar3_mutate_diff:valid_ref("a1b2c3d")).

%% A fork PR's head ref reaches this unfiltered, and git reads a leading dash
%% as an option: "HEAD~1 --output=/tmp/x" wrote attacker-chosen bytes to disk.
valid_ref_rejects_option_injection_test() ->
    ?assertNot(rebar3_mutate_diff:valid_ref("--output=/tmp/pwned")),
    ?assertNot(rebar3_mutate_diff:valid_ref("-o/tmp/pwned")),
    ?assertNot(rebar3_mutate_diff:valid_ref("HEAD~1 --output=/tmp/pwned")),
    ?assertNot(rebar3_mutate_diff:valid_ref("main\nrm -rf /")),
    ?assertNot(rebar3_mutate_diff:valid_ref("")).

changed_lines_rejects_invalid_ref_without_running_git_test() ->
    Marker = "/tmp/rebar3_mutate_should_not_exist",
    file:delete(Marker),
    Result = rebar3_mutate_diff:changed_lines("HEAD~1 --output=" ++ Marker),
    ?assertMatch({error, {invalid_base_ref, _}}, Result),
    ?assertEqual(false, filelib:is_file(Marker)).

%%====================================================================
%% Path matching
%%====================================================================

matches_path_is_anchored_on_a_component_test() ->
    ?assert(rebar3_mutate_diff:matches_path("/home/x/src/b.erl", "src/b.erl")),
    ?assert(rebar3_mutate_diff:matches_path("src/b.erl", "src/b.erl")),
    ?assertNot(rebar3_mutate_diff:matches_path("/home/x/src/sub_b.erl", "src/b.erl")),
    ?assertNot(rebar3_mutate_diff:matches_path("/home/x/src/ab.erl", "b.erl")).
