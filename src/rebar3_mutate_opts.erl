-module(rebar3_mutate_opts).

-export([epp/2, compile/1]).

%% Translates the project's erl_opts into options for epp and for compile:forms.
%%
%% Without this, a module is parsed with only TEST defined, so anything behind
%% -ifdef resolves to the branch the project does not build: the plugin mutates
%% code that never ships, reports a score for it, and says nothing.
-spec epp([term()], [file:filename()]) -> [term()].
epp(ErlOpts, IncludeDirs) ->
    [
        {includes, IncludeDirs ++ includes(ErlOpts)},
        {macros, with_test(macros(ErlOpts))}
        | features(ErlOpts)
    ].

%% compile:forms/2 receives forms epp has already expanded, so defines and
%% include paths are spent by then; parse transforms and feature enables are
%% not. warnings_as_errors is deliberately dropped - a mutant routinely leaves a
%% variable unused, and turning that into a compile error would quietly shrink
%% the pool of mutants that ever run a test.
-spec compile([term()]) -> [term()].
compile(ErlOpts) ->
    [binary, return_errors] ++ [Opt || Opt <- ErlOpts, forwardable(Opt)].

%%====================================================================
%% Internal
%%====================================================================

includes(ErlOpts) ->
    [Dir || {i, Dir} <- ErlOpts].

%% epp rejects a macro defined twice with {redefine, Key}, and the test profile
%% rebar3 runs this provider in already defines TEST, so the list has to be
%% deduplicated rather than simply prepended to.
macros(ErlOpts) ->
    unique(lists:append([macro(Opt) || Opt <- ErlOpts])).

macro({d, Key}) -> [{Key, true}];
macro({d, Key, Value}) -> [{Key, Value}];
macro(_) -> [].

with_test(Macros) ->
    case lists:keymember('TEST', 1, Macros) of
        true -> Macros;
        false -> [{'TEST', true} | Macros]
    end.

unique([]) -> [];
unique([{Key, _} = Macro | Rest]) -> [Macro | unique([M || {K, _} = M <- Rest, K =/= Key])].

features(ErlOpts) ->
    case [Feature || {feature, Feature, enable} <- ErlOpts] of
        [] -> [];
        Features -> [{features, Features}]
    end.

forwardable({parse_transform, _}) -> true;
forwardable({feature, _, _}) -> true;
forwardable(Opt) when is_atom(Opt) -> lists:prefix("nowarn_", atom_to_list(Opt));
forwardable(_) -> false.
