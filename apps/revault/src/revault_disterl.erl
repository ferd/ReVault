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
-export([callback/1, mode/1, peer/2, peer/3, accept_peer/2, unpeer/2, send/2, reply/3, unpack/1]).
-define(VSN, 1).
-type state() :: ?MODULE.
-export_type([state/0]).

-spec callback(term()) -> state().
callback(_) -> ?MODULE.

-spec mode(client|server) -> state().
mode(_) ->
    ?MODULE.

peer(FromName, {ToName, ToNode}) ->
    %% TODO: change this to a Maybe construct in OTP-25
    FromNode = node(),
    Payload = revault_data_wrapper:peer({FromName, FromNode}),
    case FromNode == ToNode orelse lists:member(ToNode, nodes()) of
        true ->
            send({ToName, ToNode}, Payload);
        false ->
            case net_adm:ping(ToNode) of
                pong ->
                    send({ToName, ToNode}, Payload);
                pang ->
                    {error, disterl_connection}
            end
    end.

peer(FromName, {ToName, ToNode}, UUID) ->
    %% TODO: change this to a Maybe construct in OTP-25
    FromNode = node(),
    Payload = revault_data_wrapper:peer({FromName, FromNode}, UUID),
    case FromNode == ToNode orelse lists:member(ToNode, nodes()) of
        true ->
            send({ToName, ToNode}, Payload);
        false ->
            case net_adm:ping(ToNode) of
                pong ->
                    send({ToName, ToNode}, Payload);
                pang ->
                    {error, disterl_connection}
            end
    end.

accept_peer(_ToName, _Marker) ->
    %% No need to actually track any sort of data
    ok.

unpeer(_FromName, _ToName) ->
    %% No need to actually unset any sort of connections over distributed erlang.
    ok.

send(Remote, Payload) ->
    %% TODO: This code here assumes all peers are on the same version
    %%       since distributed erlang is mostly used as a test layer.
    %%       This assumption lets us unpack the payload here.
    %%       If we expected mixed protocol versions, we should have a
    %%       stateful receiving process on the remote end that handles
    %%       the unpacking translation, which we ignore for conciseness
    %%       right now.
    Ref = make_ref(),
    case call(Remote, {revault, Ref, unpack(Payload)}) of
        ok -> {ok, Ref};
        {error,_} = E -> E
    end.

reply(From, Ref, Payload) ->
    %% TODO: see note in send/2
    Msg = {revault, Ref, unpack(Payload)},
    call(From, Msg).


%% For this module, we just use raw erlang terms.
unpack({peer, ?VSN, Remote}) -> {peer, Remote};
unpack({peer, ?VSN, Remote, UUID}) -> {peer, Remote, UUID};
unpack({ask, ?VSN}) -> ask;
unpack({ok, ?VSN}) -> ok;
unpack({error, ?VSN, R}) -> {error, R};
unpack({manifest, ?VSN}) -> manifest;
unpack({manifest, ?VSN, Data}) -> {manifest, Data};
unpack({file, ?VSN, Path, Meta, Bin}) -> {file, Path, Meta, Bin};
unpack({fetch, ?VSN, Path}) -> {fetch, Path};
unpack({sync_complete, ?VSN}) -> sync_complete;
unpack({conflict_file, ?VSN, WorkPath, Path, Count, Meta, Bin}) ->
    {conflict_file, WorkPath, Path, Count, Meta, Bin};
unpack(Term) ->
    Term.


%%%%%%%%%%%%%%%
%%% PRIVATE %%%
%%%%%%%%%%%%%%%
call({Name, Node}, Msg) ->
    try
        erpc:call(Node, gproc, send, [{n, l, {revault_fsm, Name}}, Msg]),
        ok
    catch
        E:R -> {error, {E,R}}
    end.
