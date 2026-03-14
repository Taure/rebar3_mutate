-module(rebar3_mutate).

-export([init/1]).

init(State) ->
    rebar3_mutate_prv:init(State).
