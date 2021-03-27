%%% @doc Protocol handler in charge of ITC ID synchronization.
%%%
%%% A core assumption of this module is that either parties being
%%% contacted are assumed to already be started and addressable.
%%%
%%% I.e. the idea here is to communicate with stateful processes
%%% we know are already in place into a running system, and provide
%%% concrete data that can then be handed off to some format-specific
%%% converters to deal with various encodings and wire formats.
%%%
%%% One important thing to note is that while we expect the server-side
%%% (with an already-created ID) to exist, we can't make that assumption
%%% from the client side if it does not exist yet, since booting it
%%% through `revault_dirmon_tracker' requires passing in the seed ID.
%%%
%%% This implies that the ID will be stored somewhere stateful, but the
%%% protocol here does not need to know where or how.
-module(revault_id_sync).
-export([ask/0, reply/2]).
-define(VSN, 1).
%-define(name(N), {via, gproc, {n,l,{?MODULE,N}}}).
new() ->
    revault_id:new().

ask() ->
    {ask, ?VSN}.

reply({ask, ?VSN}, Id) ->
    {Keep, Send} = revault_id:fork(Id),
    {Keep, {reply, Send}}.

send({Name, Node}, Payload) ->
    Ref = make_ref(),
    From = self(),
    ok = erpc:cast(Node, fun() ->
        gproc:send(Name, {revault, {?MODULE, From, Ref}, Payload})
    end),
    Ref.

send_back({?MODULE, From, Ref}, Payload) ->
    From ! {revault, {self(), Ref}, Payload},
    ok.

%% For this module, we just use raw erlang terms.
unpack({ask, ?VSN}) -> ask;
unpack(Term) -> Term.
