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
-export([callback/1, mode/2, peer/3, unpeer/3, send/3, reply/4, unpack/2]).

-record(state, {name, dirs, mode}).
-type state() :: {?MODULE, term()}.
-export_type([state/0]).

-spec callback(term()) -> state().
callback({Name, DirOpts}) ->
    {?MODULE, #state{name=Name, dirs=DirOpts}}.

-spec mode(client|server, state()) -> {term(), state()}.
mode(Mode, S=#state{name=Name, dirs=DirOpts}) ->
    Res = case Mode of
        client ->
            revault_protocols_tcp_sup:start_client(Name, DirOpts);
        server ->
            revault_protocols_tcp_sup:start_server(Name, DirOpts)
    end,
    {Res, {?MODULE, S#state{mode=Mode}}}.

%% @doc only callable from the client-side.
peer(Local, Peer=Dir, S=#state{dirs=#{<<"peers">> := Peers}}) ->
    #{Peer := Map} = Peers,
    Payload = {revault, make_ref(), revault_data_wrapper:peer(Dir)},
    {revault_tcp_client:peer(Local, Peer, Map, Payload), {?MODULE, S}}.

unpeer(_, _, _) -> error(undef).
send(_, _, _) -> error(undef).

% [Remote, Marker, revault_data_wrapper:ok()]),
reply(Remote, Marker, Payload, S=#state{name=Name, mode=client}) ->
    {revault_tcp_client:reply(Name, Remote, Marker, Payload),
     {?MODULE, S}};
reply(Remote, Marker, Payload, S=#state{name=Name, mode=server}) ->
    {revault_tcp_serv:reply(Name, Remote, Marker, Payload),
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
unpack({ask, ?VSN}) -> ask;
unpack({ok, ?VSN}) -> ok;
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

send_local(Name, Payload) ->
    gproc:send({n, l, {revault_fsm, Name}}, Payload).
