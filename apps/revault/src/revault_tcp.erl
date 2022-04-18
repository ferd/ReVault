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

-spec mode(client|server, state()) -> state().
mode(Mode, S=#state{name=Name, dirs=DirOpts}) ->
    case Mode of
        client ->
            revault_protocols_tcp_sup:start_client(Name, DirOpts);
        server ->
            revault_protocols_tcp_sup:start_server(Name, DirOpts)
    end,
    {?MODULE, S#state{mode=Mode}}.

%% @doc only callable from the client-side.
peer(_, _, _) -> error(undef).
unpeer(_, _, _) -> error(undef).
send(_, _, _) -> error(undef).
reply(_, _, _, _) -> error(undef).
unpack(_, _) -> error(undef).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% INTERNAL SHARED CALLS %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
wrap({peer, _Dir} = Msg) -> wrap_(Msg);
wrap(ask) -> wrap_(ask);
wrap(ok) -> wrap_(ok);
wrap({error, _} = Msg) -> wrap_(Msg);
wrap(manifest = Msg) -> wrap_(Msg);
wrap({manifest, _Data} = Msg) -> wrap_(Msg);
wrap({file, _Path, _Meta, _Bin} = Msg) -> wrap_(Msg);
wrap({fetch, _Path} = Msg) -> wrap_(Msg);
wrap(sync_complete = Msg) -> wrap_(Msg);
wrap({conflict_file, _WorkPath, _Path, _Meta, _Bin} = Msg) -> wrap_(Msg).

wrap_(Msg) ->
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
            {ok, ?VSN, binary_to_term(Term), Rest}
    end;
unwrap(<<_/binary>>) ->
    {error, incomplete}.

send_local(Name, Payload) ->
    From = self(),
    gproc:send({n, l, {revault_sync_fsm, Name}},
               {revault, From, Payload}).
