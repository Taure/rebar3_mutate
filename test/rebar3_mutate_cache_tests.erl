-module(rebar3_mutate_cache_tests).

-include_lib("eunit/include/eunit.hrl").

load_missing_test() ->
    Cache = rebar3_mutate_cache:load("/tmp/rebar3_mutate_cache_test_nonexistent"),
    ?assertEqual(#{}, Cache).

save_and_load_test() ->
    Dir = "/tmp/rebar3_mutate_cache_test",
    Hash = <<"abc123">>,
    Cache = #{
        {my_mod, op_arithmetic, 10, Hash} => killed,
        {my_mod, op_boolean, 20, Hash} => survived
    },
    ok = rebar3_mutate_cache:save(Dir, Cache),
    Loaded = rebar3_mutate_cache:load(Dir),
    ?assertEqual(Cache, Loaded),
    file:delete(filename:join([Dir, ".mutate_cache", "results.term"])),
    file:del_dir(filename:join(Dir, ".mutate_cache")).

lookup_hit_test() ->
    Hash = <<"abc123">>,
    Cache = #{{my_mod, op_arithmetic, 10, Hash} => killed},
    Point = {mutation_point, 0, op_arithmetic, 10, dummy, dummy},
    ?assertEqual({hit, killed}, rebar3_mutate_cache:lookup(Cache, my_mod, Point, Hash)).

lookup_miss_test() ->
    Hash = <<"abc123">>,
    Cache = #{{my_mod, op_arithmetic, 10, Hash} => killed},
    Point = {mutation_point, 0, op_boolean, 20, dummy, dummy},
    ?assertEqual(miss, rebar3_mutate_cache:lookup(Cache, my_mod, Point, Hash)).

lookup_empty_cache_test() ->
    Point = {mutation_point, 0, op_arithmetic, 10, dummy, dummy},
    ?assertEqual(miss, rebar3_mutate_cache:lookup(#{}, my_mod, Point, <<"hash">>)).

lookup_stale_hash_test() ->
    OldHash = <<"old">>,
    NewHash = <<"new">>,
    Cache = #{{my_mod, op_arithmetic, 10, OldHash} => killed},
    Point = {mutation_point, 0, op_arithmetic, 10, dummy, dummy},
    ?assertEqual(miss, rebar3_mutate_cache:lookup(Cache, my_mod, Point, NewHash)).

file_hash_test() ->
    Dir = "/tmp/rebar3_mutate_hash_test",
    filelib:ensure_dir(filename:join(Dir, "dummy")),
    File = filename:join(Dir, "test.erl"),
    ok = file:write_file(File, "hello"),
    Hash1 = rebar3_mutate_cache:file_hash(File),
    ?assert(is_binary(Hash1)),
    ?assert(byte_size(Hash1) > 0),
    ok = file:write_file(File, "world"),
    Hash2 = rebar3_mutate_cache:file_hash(File),
    ?assertNotEqual(Hash1, Hash2),
    file:delete(File).

file_hash_missing_test() ->
    ?assertEqual(<<>>, rebar3_mutate_cache:file_hash("/nonexistent/file.erl")).
