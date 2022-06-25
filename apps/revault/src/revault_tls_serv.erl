%%% Start a TLS server to be used for multiple directories and peers.
%%% The server should work with a config that contains standard TLS/Inet
%%% options, the list of allowed directories to sync.
%%% The TLS certificate used defines whether the client is allowed to
%%% reach a specific directory.
%%%
%%% What we do once authenticated is just proxy and serialize messages
%%% that the sync servers will use, and hopefully simplify their reception
%%% model by moving the message decoding outside of their main loop, which
%%% really messes with the FSM mechanism.
%%%
%%% The proxy/server may or may not reorganize file streams by buffering
%%% or fragmenting their content to fit memory or throughput limits; this
%%% is possible because we do not expect explicit acks and want to deal
%%% with interrupts and broken transfers with end-to-end retries.
-module(revault_tls_serv).
-export([start_link/2, start_link/3, update_dirs/2, stop/1]).
-export([accept_peer/3, unpeer/3, reply/5]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-behaviour(gen_server).

-include("revault_tls.hrl").

%%%%%%%%%%%%%%%%%%
%%% PUBLIC API %%%
%%%%%%%%%%%%%%%%%%
start_link(Name, DirOpts) ->
    start_link(Name, DirOpts,
          [{delay_send, true}, {keepalive, true},
           {linger, {true, 0}}, {reuseaddr, true}]).

start_link(Name, DirOpts, TlsOpts) ->
    MandatoryOpts = [{mode, binary}, {packet, raw}, {active, false}],
    AllTlsOpts = MandatoryOpts ++ TlsOpts,
    gen_server:start_link(?SERVER(Name), ?MODULE, {Name, DirOpts, AllTlsOpts}, []).

stop(Name) ->
    gen_server:call(?SERVER(Name), stop).

update_dirs(Name, DirOpts) ->
    gen_server:call(?SERVER(Name), {dirs, DirOpts}).

accept_peer(_Name, _Dir, {Pid,_Marker}) ->
    {ok, Pid}.

unpeer(Name, _Dir, Pid) ->
    gen_server:call(?SERVER(Name), {disconnect, Pid}, infinity).

reply(Name, _Dir, _Pid, {Pid,Marker}, Payload) ->
    %% Gotcha here: we forget the first _Pid (the remote) and use the one that
    %% was bundled with the Marker because it's possible that multiple clients
    %% at once are contacting the server and we need to respond to many with
    %% a busy message.
    gen_server:call(?SERVER(Name), {fwd, Pid, {revault, Marker, Payload}}, infinity).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% GEN_SERVER / MANAGEMENT %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% We can use a single acceptor process loop because we rather expect
%% the heavy work to be done by the sync servers and the worker loops,
%% not the acceptor. It also simplifies the handling of auth and
%% permissions.
% {server => auth => none => sync
init({Name, #{<<"server">> := #{<<"auth">> := #{<<"tls">> := DirOpts}}}, TlsOpts}) ->
    #{<<"port">> := Port, <<"status">> := Status, <<"authorized">> := Clients,
      <<"certfile">> := CertFile, <<"keyfile">> := KeyFile} = DirOpts,
    %% Gather all peer opts for all valid certs and call revault_tls:pin_certfiles_opts/1
    %% on them for the peer auth; then match certs for authorization later.
    CertFiles = [maps:get(<<"certfile">>, Client)
                 || {_Name, Client} <- maps:to_list(Clients)],
    PinOpts = revault_tls:pin_certfiles_opts(CertFiles) ++
              [{certfile, CertFile}, {keyfile, KeyFile}],
    case Status of
        enabled ->
            case ssl:listen(Port, PinOpts ++ TlsOpts) of
                {error, Reason} ->
                    {stop, {listen,Reason}};
                {ok, LSock} ->
                    process_flag(trap_exit, true),
                    self() ! accept,
                    {ok, #serv{name=Name, dirs=DirOpts, opts=TlsOpts, sock=LSock}}
            end;
        disabled ->
            {stop, disabled}
    end;
init(_) ->
    {stop, disabled}.

handle_call({dirs, Opts}, _From, S=#serv{}) ->
    #{<<"server">> := #{<<"auth">> := #{<<"tls">> := DirOpts}}} = Opts,
    %% TODO: handle port change
    %% TODO: handle status: disabled
    {reply, ok, S#serv{dirs=DirOpts}};
handle_call({disconnect, Pid}, _From, S=#serv{workers=W}) ->
    case W of
        #{Pid := _} ->
            %% Here we do a synchronous block; we fully expect the
            %% worker process to still be present for this termination
            %% to work, since the pid is tracked. This means that
            %% we can synchronously reply to the caller once we receive
            %% the worker's death.
            %% We do this because it's possible there's a race condition
            %% where the remote connection closes at the same time our
            %% caller here tries to, and if we let the worker respond, it
            %% may already be dead.
            Pid ! disconnect,
            receive
                {'EXIT', Pid, _Reason} ->
                    Workers = maps:remove(Pid, W),
                    {reply, ok, S#serv{workers=Workers}}
            end;
        _ ->
            {reply, ok, S}
    end;
handle_call({fwd, Pid, Msg}, From, S=#serv{}) ->
    Pid ! {fwd, From, Msg},
    {noreply, S};
handle_call(stop, _From, S=#serv{}) ->
    NewS = stop_server(S),
    {stop, {shutdown, stop}, ok, NewS};
handle_call(_, _From, State) ->
    {noreply, State}.

handle_cast(_Info, State) ->
    {noreply, State}.

handle_info(accept, S=#serv{name=Name, sock=LSock, dirs=Opts, workers=W}) ->
    case ssl:transport_accept(LSock, ?ACCEPT_WAIT) of
        {ok, HSock} ->
            case ssl:handshake(HSock, ?ACCEPT_WAIT) of
                {error, _Reason} -> % don't crash on bad TLS, this is super common
                    self() ! accept,
                    {noreply, S};
                {ok, Sock} ->
                    Worker = start_linked_worker(Name, Sock, Opts),
                    self() ! accept,
                    {noreply, S#serv{workers=W#{Worker => Sock}}}
            end;
        {error, timeout} ->
            %% self-interrupt to let other code have an access to things
            self() ! accept,
            {noreply, S};
        {error, Reason} ->
            {stop, {accept, Reason}}
    end;
handle_info({'EXIT', Worker, _}, S=#serv{workers=W}) ->
    Workers = maps:remove(Worker, W),
    {noreply, S#serv{workers=Workers}}.

terminate(_Reason, #serv{workers=W}) ->
    [exit(Pid, shutdown) || Pid <- maps:keys(W)],
    ok.

%%%%%%%%%%%%%%%%%%%
%%% WORKER LOOP %%%
%%%%%%%%%%%%%%%%%%%
start_linked_worker(LocalName, Sock, Opts) ->
    %% TODO: stick into a supervisor
    Pid = spawn_link(fun() -> worker_init(LocalName, Opts) end),
    _ = ssl:controlling_process(Sock, Pid),
    Pid ! {ready, Sock},
    Pid.

worker_init(LocalName, Opts) ->
    receive
        {ready, Sock} ->
            worker_dispatch(#conn{localname=LocalName, sock=Sock, dirs=Opts})
    end.

worker_dispatch(C=#conn{localname=Name, sock=Sock, dirs=Dirs, buf=Buf}) ->
    %% wrap the marker into a local one so that the responses
    %% can come to the proper connection process. There can be multiple
    %% TLS servers active for a single one and the responses must go
    %% to the right place.
    {ok, ?VSN, Msg, NewBuf} = next_msg(Sock, Buf),
    #{<<"sync">> := DirNames} = Dirs,
    case Msg of
        {revault, Marker, {peer, Dir}} ->
            case lists:member(Dir, DirNames) of
                true ->
                    ssl:setopts(Sock, [{active, once}]),
                    revault_tls:send_local(Name, {revault, {self(),Marker}, {peer, self()}}),
                    worker_loop(Dir, C#conn{buf=NewBuf});
                false ->
                    ssl:send(Sock, revault_tcp:wrap({revault, Marker, {error, eperm}})),
                    ssl:close(Sock)
            end;
        _ ->
            Msg = {revault, internal, revault_data_wrapper:error(protocol)},
            ssl:send(Sock, revault_tls:wrap(Msg)),
            ssl:close(Sock)
    end.

worker_loop(Dir, C=#conn{localname=Name, sock=Sock, buf=Buf0}) ->
    receive
        {revault, _From, Msg} ->
            Payload = revault_tls:wrap(Msg),
            ssl:send(Sock, Payload),
            worker_loop(Dir, C);
        {fwd, From, Msg} ->
            Payload = revault_tls:wrap(Msg),
            Res = ssl:send(Sock, Payload),
            gen_server:reply(From, Res),
            worker_loop(Dir, C);
        disconnect ->
            ssl:close(Sock),
            exit(normal);
        {tcp, Sock, Data} ->
            ssl:setopts(Sock, [{active, once}]),
            case revault_tls:unwrap(<<Buf0/binary, Data/binary>>) of
                {error, incomplete} ->
                    worker_loop(Dir, C#conn{buf = <<Buf0/binary, Data/binary>>});
                {ok, ?VSN, Payload, NewBuf} ->
                    {revault, Marker, Msg} = Payload,
                    revault_tls:send_local(Name, {revault, {self(), Marker}, Msg}),
                    worker_loop(Dir, C#conn{buf = NewBuf})
            end;
        {tcp_error, Sock, Reason} ->
            exit(Reason);
        {tcp_closed, Sock} ->
            exit(normal)
    end.


%%%%%%%%%%%%%%%
%%% HELPERS %%%
%%%%%%%%%%%%%%%
stop_server(S=#serv{workers = WorkerMap}) ->
    [begin
         Pid ! stop,
         receive {'EXIT', Pid, _} -> ok end
     end || Pid <- maps:keys(WorkerMap)],
    S#serv{workers=#{}}.

next_msg(Sock, Buf) ->
    case revault_tls:unwrap(Buf) of
        {ok, Vsn, Msg, NewBuf} ->
            {ok, Vsn, Msg, NewBuf};
        {error, incomplete} ->
            case ssl:recv(Sock, 0) of
                {ok, Bytes} ->
                    next_msg(Sock, <<Buf/binary, Bytes/binary>>);
                {error, Term} ->
                    {error, Term}
            end
    end.

