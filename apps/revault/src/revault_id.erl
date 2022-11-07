%%% @doc high-level convenience wrapper around the ITC
%%% library for Revault's internal use cases.
-module(revault_id).
-export([new/0, undefined/0, fork/1]).

-spec new() -> itc:id().
new() ->
    {Id, _} = itc:explode(itc:seed()),
    Id.

-spec undefined() -> undefined.
undefined() ->
    undefined.

-spec fork(itc:id()) -> {itc:id(), itc:id()}.
fork(Id) ->
    {_, Event} = itc:explode(itc:seed()),
    {L, R} = itc:fork(itc:rebuild(Id, Event)),
    {IdL, _} = itc:explode(L),
    {IdR, _} = itc:explode(R),
    {IdL, IdR}.
