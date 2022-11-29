%%% Shared definitions between revault_tcp_serv and revault_tcp_client.
%%% Both the client and the server implement a process with a reception
%%% loop to which this module can send messages and read from them.
%%%
%%% There is one internal API to be used by revault_sync_fsm, and
%%% one internal API to be used by the client and servers.
-module(revault_tcp).

-include("revault_tcp.hrl").

%% stack-specific calls to be made from an initializing process and that
%% are not generic.
-export([wrap/1, unwrap/1, send_local/2]).
%% callbacks from within the FSM
-export([callback/1, mode/2, peer/3, peer/4, accept_peer/3, unpeer/3, send/3, reply/4, unpack/2]).

-record(state, {proc, name, dirs, mode, serv_conn}).
-type state() :: term().
-type cb_state() :: {?MODULE, state()}.
-export_type([state/0]).

-spec callback(term()) -> state().
callback({Name, DirOpts}) ->
    {?MODULE, #state{proc=Name, name=Name, dirs=DirOpts}};
callback({Proc, Name, DirOpts}) ->
    {?MODULE, #state{proc=Proc, name=Name, dirs=DirOpts}}.

-spec mode(client|server, state()) -> {term(), cb_state()}.
mode(Mode, S=#state{proc=Proc, dirs=DirOpts}) ->
    Res = case Mode of
        client ->
            revault_protocols_tcp_sup:start_client(Proc, DirOpts);
        server ->
            revault_protocols_tcp_sup:start_server(Proc, DirOpts)
    end,
    {Res, {?MODULE, S#state{mode=Mode}}}.

%% @doc only callable from the client-side.
peer(Local, Peer, S=#state{name=Dir, dirs=#{<<"peers">> := Peers}}) ->
    case Peers of
        #{Peer := Map} ->
            Payload = {revault, make_ref(), revault_data_wrapper:peer(Dir)},
            {revault_tcp_client:peer(Local, Peer, Map, Payload), {?MODULE, S}};
        _ ->
            {{error, unknown_peer}, {?MODULE, S}}
    end.

peer(Local, Peer, UUID, S=#state{name=Dir, dirs=#{<<"peers">> := Peers}}) ->
    case Peers of
        #{Peer := Map} ->
            Payload = {revault, make_ref(), revault_data_wrapper:peer(Dir, UUID)},
            {revault_tcp_client:peer(Local, Peer, Map, Payload), {?MODULE, S}};
        _ ->
            {{error, unknown_peer}, {?MODULE, S}}
    end.

accept_peer(Remote, Marker, S=#state{proc=Proc}) ->
    {ok, Conn} = revault_tcp_serv:accept_peer(Proc, Remote, Marker),
    {ok, {?MODULE, S#state{serv_conn=Conn}}}.

unpeer(Proc, Remote, S=#state{mode=client}) ->
    {revault_tcp_client:unpeer(Proc, Remote),
     {?MODULE, S}};
unpeer(Proc, Remote, S=#state{mode=server, serv_conn=Conn}) ->
    {revault_tcp_serv:unpeer(Proc, Remote, Conn),
     {?MODULE, S#state{serv_conn=undefined}}}.

%% @doc only callable from the client-side, server always replies.
send(Remote, Payload, S=#state{proc=Proc, mode=client}) ->
    Marker = make_ref(),
    Res = case revault_tcp_client:send(Proc, Remote, Marker, Payload) of
        ok -> {ok, Marker};
        Other -> Other
    end,
    {Res, {?MODULE, S}}.

% [Remote, Marker, revault_data_wrapper:ok()]),
reply(Remote, Marker, Payload, S=#state{proc=Proc, mode=client}) ->
    {revault_tcp_client:reply(Proc, Remote, Marker, Payload),
     {?MODULE, S}};
reply(Remote, Marker, Payload, S=#state{proc=Proc, mode=server, serv_conn=Conn}) ->
    {revault_tcp_serv:reply(Proc, Remote, Conn, Marker, Payload),
     {?MODULE, S}}.

unpack(_, _) -> error(undef).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% INTERNAL SHARED CALLS %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
wrap({revault, _Marker, _Payload}=Msg) ->
    Bin = term_to_binary(Msg, [compressed, {minor_version, 2}]),
    %% Tag by length to ease parsing.
    %% Prepare extra versions that could do things like deal with
    %% signed messages and add options and whatnot, or could let
    %% us spin up legacy state machines whenever that could happen.
    %%
    %% If we need more than 18,000 petabytes for a message and more
    %% than 65535 protocol versions, we're either very successful or
    %% failing in bad ways.
    <<(byte_size(Bin)):64/unsigned, ?VSN:16/unsigned, Bin/binary>>.

unwrap(<<Size:64/unsigned, ?VSN:16/unsigned, Payload/binary>>) ->
    case byte_size(Payload) of
        Incomplete when Incomplete < Size ->
            {error, incomplete};
        _ ->
            <<Term:Size/binary, Rest/binary>> = Payload,
            {revault, Marker, Msg} = binary_to_term(Term),
            {ok, ?VSN, {revault, Marker, unpack(Msg)}, Rest}
    end;
unwrap(<<_/binary>>) ->
    {error, incomplete}.

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

send_local(Proc, Payload) ->
    gproc:send({n, l, {revault_fsm, Proc}}, Payload).
