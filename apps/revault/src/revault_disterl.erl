%%% @doc Protocol handler in charge of translations and callback
%%% handling over distributed Erlang.
%%%
%%% A core assumption of this module is that either parties being
%%% contacted are assumed to already be started and addressable,
%%% and that this may be handled by a stateful component
%%% that wraps communications. A similar expectation is put on
%%% SSH and TCP protocols, which would have different handshake
%%% requirements and couldn't be made generic in the FSM handler.
%%%
%%% I.e. the idea here is to communicate with stateful processes
%%% we know are already in place into a running system, and provide
%%% concrete data that can then be handed off to some format-specific
%%% converters to deal with various encodings and wire formats.
-module(revault_disterl).
-export([send/2, reply/2, unpack/1]).
-define(VSN, 1).

send({Name, Node}, Payload) ->
    %% TODO: This code here assumes all peers are on the same version
    %%       since distributed erlang is mostly used as a test layer.
    %%       This assumption lets us unpack the payload here.
    %%       If we expected mixed protocol versions, we should have a
    %%       stateful receiving process on the remote end that handles
    %%       the unpacking translation, which we ignore for conciseness
    %%       right now.
    Ref = make_ref(),
    From = self(),
    try
        erpc:call(Node, gproc, send,
                  [{n, l, {revault_sync_fsm, Name}},
                   {revault, {?MODULE, From, Ref}, unpack(Payload)}]),
        {ok, Ref}
    catch
        E:R -> {error, {E,R}}
    end.

reply({?MODULE, From, Ref}, Payload) ->
    %% TODO: see note in send/2
    From ! {revault, {?MODULE, self(), Ref}, unpack(Payload)},
    ok.

%% For this module, we just use raw erlang terms.
unpack({ask, ?VSN}) -> ask;
unpack({error, ?VSN, R}) -> {error, R};
unpack({manifest, ?VSN}) -> manifest;
unpack({manifest, ?VSN, Data}) -> {manifest, Data};
unpack({file, ?VSN, Path, Meta, Bin}) -> {file, Path, Meta, Bin};
unpack({fetch, ?VSN, Path}) -> {fetch, Path};
unpack({sync_complete, ?VSN}) -> sync_complete;
unpack({conflict_file, ?VSN, WorkPath, Path, Meta, Bin}) ->
    {conflict_file, WorkPath, Path, Meta, Bin};
unpack(Term) ->
    Term.
