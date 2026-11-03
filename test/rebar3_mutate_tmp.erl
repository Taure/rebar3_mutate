-module(rebar3_mutate_tmp).

-export([dir/0, remove/1]).

%% A fresh directory per call, private to the user. A shared fixed path under
%% /tmp, put first on the code path, let concurrent runs and other users'
%% files stand in for the modules a test builds.
-spec dir() -> file:filename().
dir() ->
    Name =
        "rebar3_mutate_" ++ os:getpid() ++ "_" ++
            integer_to_list(erlang:unique_integer([positive])) ++ "_" ++
            integer_to_list(rand:uniform(1 bsl 32)),
    Dir = filename:join(base(), Name),
    ok = file:make_dir(Dir),
    ok = file:change_mode(Dir, 8#700),
    Dir.

-spec remove(file:filename()) -> ok.
remove(Dir) ->
    _ = code:del_path(Dir),
    ok = file:del_dir_r(Dir).

base() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        "" -> "/tmp";
        TmpDir -> TmpDir
    end.
