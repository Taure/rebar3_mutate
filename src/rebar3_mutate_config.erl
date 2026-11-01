-module(rebar3_mutate_config).

-export([parse/1]).

-type config() :: #{eunit_tests := #{module() => [module(), ...]}}.

-export_type([config/0]).

-define(KNOWN_OPTIONS, [eunit_tests]).

%% Validates the `mutate` section of rebar.config. A typo here must stop the
%% run: an unknown key or a missing test module that was silently ignored would
%% let the plugin score modules against fewer tests than the project asked for.
-spec parse(term()) -> {ok, config()} | {error, string()}.
parse(Options) ->
    try
        Checked = options(Options),
        {ok, #{eunit_tests => eunit_tests(Checked)}}
    catch
        throw:{invalid_config, Message} -> {error, Message}
    end.

%%====================================================================
%% Internal
%%====================================================================

options(Options) when is_list(Options) ->
    Keys = [key(Option) || Option <- Options],
    case Keys -- lists:usort(Keys) of
        [] -> Options;
        [Duplicate | _] -> invalid("mutate option ~p is set more than once", [Duplicate])
    end;
options(Other) ->
    invalid("mutate config must be a list of {Key, Value} tuples, got ~p", [Other]).

key({Key, _Value}) when is_atom(Key) ->
    case lists:member(Key, ?KNOWN_OPTIONS) of
        true ->
            Key;
        false ->
            invalid("Unknown mutate option ~p; known options: ~s", [
                Key, lists:join(", ", [atom_to_list(K) || K <- ?KNOWN_OPTIONS])
            ])
    end;
key(Other) ->
    invalid("mutate options must be {Key, Value} tuples, got ~p", [Other]).

eunit_tests(Options) ->
    case lists:keyfind(eunit_tests, 1, Options) of
        false ->
            #{};
        {eunit_tests, Mapping} when is_map(Mapping) ->
            #{
                Checked => test_modules(Checked, Tests)
             || {Source, Tests} <- lists:sort(maps:to_list(Mapping)),
                Checked <- [source_module(Source)]
            };
        {eunit_tests, Other} ->
            invalid("eunit_tests must be a map of module => [test_module], got ~p", [Other])
    end.

source_module(Source) when is_atom(Source) ->
    case exists(Source) of
        true -> Source;
        false -> invalid("eunit_tests: source module ~p was not found", [Source])
    end;
source_module(Other) ->
    invalid("eunit_tests: keys must be module names (atoms), got ~p", [Other]).

test_modules(Source, [_ | _] = Tests) ->
    case Tests -- lists:usort(Tests) of
        [] -> ok;
        [Duplicate | _] -> invalid("eunit_tests: ~p lists ~p more than once", [Source, Duplicate])
    end,
    Checked = [test_module(Source, Test) || Test <- Tests],
    not_implied_by_source(Source, Checked),
    not_implied_by_each_other(Source, Checked),
    Checked;
test_modules(Source, Other) ->
    invalid("eunit_tests: ~p must map to a non-empty list of test modules, got ~p", [
        Source, Other
    ]).

test_module(Source, Test) when is_atom(Test) ->
    case {exists(Test), rebar3_mutate_runner:contributes_tests(Test)} of
        {true, true} ->
            Test;
        {false, _} ->
            invalid(
                "eunit_tests: test module ~p listed for ~p was not found; "
                "is it compiled in the test profile?",
                [Test, Source]
            );
        {true, false} ->
            invalid(
                "eunit_tests: ~p listed for ~p has no eunit tests "
                "(no exported *_test/0 or *_test_/0 in it or in ~p_tests)",
                [Test, Source, Test]
            )
    end;
test_module(Source, Other) ->
    invalid("eunit_tests: test modules for ~p must be atoms, got ~p", [Source, Other]).

%% eunit:test/2 runs <Module>_tests for Module, so listing either again would
%% be silently dropped while the run claims to count it.
not_implied_by_source(Source, Tests) ->
    Implied = [atom_to_list(Source), atom_to_list(Source) ++ "_tests"],
    case [Test || Test <- Tests, lists:member(atom_to_list(Test), Implied)] of
        [] ->
            ok;
        [Test | _] ->
            invalid(
                "eunit_tests: ~p lists ~p, which eunit already runs for it; "
                "list only other modules",
                [Source, Test]
            )
    end.

not_implied_by_each_other(Source, Tests) ->
    Names = [atom_to_list(Test) || Test <- Tests],
    case [Name || Name <- Names, lists:member(Name ++ "_tests", Names)] of
        [] ->
            ok;
        [Name | _] ->
            invalid(
                "eunit_tests: ~p lists both ~s and ~s_tests; eunit already runs ~s_tests for ~s",
                [Source, Name, Name, Name, Name]
            )
    end.

exists(Module) ->
    code:where_is_file(atom_to_list(Module) ++ ".beam") =/= non_existing.

-spec invalid(io:format(), [term()]) -> no_return().
invalid(Format, Args) ->
    throw({invalid_config, lists:flatten(io_lib:format(Format, Args))}).
