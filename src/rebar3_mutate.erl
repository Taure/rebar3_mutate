-module(rebar3_mutate).

-export([init/1, own_module/1]).

init(State) ->
    rebar3_mutate_prv:init(State).

%% The plugin runs inside the rebar3 VM and swaps modules in the one code
%% server it shares with the code under test. When a target is one of the
%% plugin's own modules those are the same module: loading the mutant makes the
%% code the provider is executing the old version, and restoring the original
%% has to purge that old version, which kills the provider and takes the VM
%% with it. Mutating the plugin with the plugin is not something a caller can
%% opt into safely, so it is refused rather than configured around.
-spec own_module(atom()) -> boolean().
own_module(Module) ->
    lists:member(Module, own_modules()).

own_modules() ->
    case application:get_key(?MODULE, modules) of
        {ok, Modules} ->
            Modules;
        undefined ->
            _ = application:load(?MODULE),
            case application:get_key(?MODULE, modules) of
                {ok, Modules} -> Modules;
                undefined -> []
            end
    end.
