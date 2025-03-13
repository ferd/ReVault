%%% Shared definitions between revault_tcp_serv and revault_tcp_client.
%%% Both the client and the server implement a process with a reception
%%% loop to which this module can send messages and read from them.
%%%
%%% There is one internal API to be used by revault_sync_fsm, and
%%% one internal API to be used by the client and servers.
-module(revault_tcp).

-include("revault_data_wrapper.hrl").
-include("revault_tcp.hrl").

%% stack-specific calls to be made from an initializing process and that
%% are not generic.
-export([wrap/1, unwrap/1, unwrap_all/1, send_local/2]).
%% callbacks from within the FSM
-export([callback/1, mode/2, peer/4, accept_peer/3, unpeer/3, send/3, reply/4, unpack/2]).

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
mode(Mode, S=#state{proc=Proc, name=Name, dirs=DirOpts}) ->
    Res = case Mode of
        client ->
            revault_protocols_tcp_sup:start_client(Proc, DirOpts);
        server ->
            %% Assumes that all servers have the full DirOpts view if this is the
            %% first place to start it.
            case revault_protocols_tcp_sup:start_server(DirOpts) of
                {ok, Pid} ->
                    revault_tcp_serv:map(Name, Proc),
                    {ok, Pid};
                {error, {already_started, Pid}} ->
                    revault_tcp_serv:map(Name, Proc),
                    {ok, Pid}
            end
    end,
    {Res, {?MODULE, S#state{mode=Mode}}}.

%% @doc only callable from the client-side.
peer(Local, Peer, Attrs, S=#state{name=Dir, dirs=#{<<"peers">> := Peers}}) ->
    case Peers of
        #{Peer := Map} ->
            Payload = {revault, make_ref(), revault_data_wrapper:peer(Dir, Attrs)},
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

unwrap_all(Buf) ->
    unwrap_all(Buf, []).

unwrap_all(Buf, Acc) ->
    case revault_tcp:unwrap(Buf) of
        {error, incomplete} ->
            {lists:reverse(Acc), Buf};
        {ok, ?VSN, Payload, NewBuf} ->
            unwrap_all(NewBuf, [Payload|Acc])
    end.

unpack({peer, ?VSN, Remote, Attrs}) -> {peer, Remote, Attrs};
unpack({ask, ?VSN}) -> ask;
unpack({ok, ?VSN}) -> ok;
unpack({error, ?VSN, R}) -> {error, R};
unpack({manifest, ?VSN}) -> manifest;
unpack({manifest, ?VSN, Data}) -> {manifest, Data};
unpack({file, ?VSN, Path, Meta, Bin}) -> {file, Path, Meta, Bin};
unpack({file, ?VSN, Path, Meta, PartNum, PartTotal, Bin}) -> {file, Path, Meta, PartNum, PartTotal, Bin};
unpack({fetch, ?VSN, Path}) -> {fetch, Path};
unpack({sync_complete, ?VSN}) -> sync_complete;
unpack({deleted_file, ?VSN, Path, Meta}) -> {deleted_file, Path, Meta};
unpack({conflict_file, ?VSN, WorkPath, deleted, Count, Meta}) ->
    {conflict_file, WorkPath, deleted, Count, Meta};
unpack({conflict_file, ?VSN, WorkPath, Path, Count, Meta, Bin}) ->
    {conflict_file, WorkPath, Path, Count, Meta, Bin};
unpack({conflict_multipart_file, ?VSN, WorkPath, Path, Count, Meta, PartNum, PartTotal, Bin}) ->
    {conflict_multipart_file, WorkPath, Path, Count, Meta, PartNum, PartTotal, Bin};
unpack(Term) ->
    Term.

send_local(Proc, Payload) ->
    gproc:send({n, l, {revault_fsm, Proc}}, Payload).
