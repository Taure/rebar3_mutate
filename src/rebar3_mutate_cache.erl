-module(rebar3_mutate_cache).

-export([load/1, save/2, lookup/4, cache_dir/0, file_hash/1]).

-define(CACHE_DIR, ".mutate_cache").
-define(CACHE_FILE, "results.term").

-type cache() :: #{cache_key() => cache_entry()}.
-type cache_key() :: {
    Module :: atom(), Operator :: atom(), Line :: pos_integer(), Hash :: binary()
}.
-type cache_entry() :: killed | survived | timed_out | {compile_error, term()}.

-export_type([cache/0]).

-spec cache_dir() -> file:filename().
cache_dir() ->
    ?CACHE_DIR.

-spec load(file:filename()) -> cache().
load(BaseDir) ->
    CacheFile = filename:join([BaseDir, ?CACHE_DIR, ?CACHE_FILE]),
    case file:consult(CacheFile) of
        {ok, [Map]} when is_map(Map) -> Map;
        _ -> #{}
    end.

-spec save(file:filename(), cache()) -> ok.
save(BaseDir, Cache) ->
    Dir = filename:join(BaseDir, ?CACHE_DIR),
    ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
    CacheFile = filename:join(Dir, ?CACHE_FILE),
    Data = io_lib:format("~p.~n", [Cache]),
    ok = file:write_file(CacheFile, Data).

-spec lookup(cache(), atom(), rebar3_mutate_ast:mutation_point(), binary()) ->
    {hit, cache_entry()} | miss.
lookup(Cache, Module, Point, SourceHash) ->
    {mutation_point, _Idx, Op, Line, _Orig, _Mutated} = Point,
    Key = {Module, Op, Line, SourceHash},
    case maps:find(Key, Cache) of
        {ok, Result} -> {hit, Result};
        error -> miss
    end.

-spec file_hash(file:filename()) -> binary().
file_hash(File) ->
    case file:read_file(File) of
        {ok, Content} -> crypto:hash(md5, Content);
        {error, _} -> <<>>
    end.
