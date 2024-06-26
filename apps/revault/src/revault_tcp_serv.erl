%%% Start a TCP server to be used for multiple directories and peers.
%%% The server should work with a config that contains standard TCP/Inet
%%% options, the list of allowed directories to sync. We do not support
%%% auth in TCP mode, SSH is to be used for that (with keys).
%%%
%%% What we do then is just proxy and serialize messages that the sync
%%% servers will use, and hopefully simplify their reception model by
%%% moving the message decoding outside of their main loop, which really
%%% messes with the FSM mechanism.
%%%
%%% The proxy/server may or may not reorganize file streams by buffering
%%% or fragmenting their content to fit memory or throughput limits; this
%%% is possible because we do not expect explicit acks and want to deal
%%% with interrupts and broken transfers with end-to-end retries.
-module(revault_tcp_serv).
%% shared callbacks
-export([start_link/1, start_link/2, update_dirs/1, map/2, stop/0]).
%% scoped callbacks
-export([accept_peer/3, unpeer/3, reply/5]).
%% behavior callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-behaviour(gen_server).

-include("revault_tcp.hrl").

%%%%%%%%%%%%%%%%%%
%%% PUBLIC API %%%
%%%%%%%%%%%%%%%%%%
start_link(DirOpts) ->
    start_link(DirOpts,
          [{delay_send, true}, {keepalive, true},
           {linger, {true, 0}}, {reuseaddr, true}]).

start_link(DirOpts, TcpOpts) ->
    MandatoryOpts = [{mode, binary}, {packet, raw}, {active, false}],
    AllTcpOpts = MandatoryOpts ++ TcpOpts,
    gen_server:start_link(?SERVER, ?MODULE, {DirOpts, AllTcpOpts}, []).

stop() ->
    gen_server:call(?SERVER, stop).

update_dirs(DirOpts) ->
    gen_server:call(?SERVER, {dirs, DirOpts}).

map(Name, Proc) ->
    gen_server:call(?SERVER, {map, Name, Proc}).

accept_peer(_Name, _Dir, {Pid,_Marker}) ->
    {ok, Pid}.

unpeer(Name, _Dir, Pid) ->
    gen_server:call(?SERVER, {disconnect, Name, Pid}, infinity).

reply(Name, _Dir, _Pid, {Pid,Marker}, Payload) ->
    %% Gotcha here: we forget the first _Pid (the remote) and use the one that
    %% was bundled with the Marker because it's possible that multiple clients
    %% at once are contacting the server and we need to respond to many with
    %% a busy message.
    gen_server:call(?SERVER, {fwd, Name, Pid, {revault, Marker, Payload}}, infinity).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% GEN_SERVER / MANAGEMENT %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% We can use a single acceptor process loop because we rather expect
%% the heavy work to be done by the sync servers and the worker loops,
%% not the acceptor. It also simplifies the handling of auth and
%% permissions.
% {server => auth => none => sync
init({#{<<"server">> := #{<<"auth">> := #{<<"none">> := DirOpts}}}, TcpOpts}) ->
    #{<<"port">> := Port, <<"status">> := Status} = DirOpts,
    case Status of
        enabled ->
            case gen_tcp:listen(Port, TcpOpts) of
                {error, Reason} ->
                    {stop, {listen,Reason}};
                {ok, LSock} ->
                    process_flag(trap_exit, true),
                    Parent = self(),
                    Acceptor = proc_lib:spawn_link(fun() -> acceptor(Parent, LSock) end),
                    {ok, #serv{dirs=DirOpts, opts=TcpOpts, sock=LSock, acceptor=Acceptor}}
            end;
        disabled ->
            {stop, disabled}
    end;
init(_) ->
    {stop, disabled}.

handle_call({dirs, Opts}, _From, S=#serv{}) ->
    #{<<"server">> := #{<<"auth">> := #{<<"none">> := DirOpts}}} = Opts,
    %% TODO: handle port change
    %% TODO: handle status: disabled
    {reply, ok, S#serv{dirs=DirOpts}};
handle_call({map, Name, Proc}, _From, S=#serv{names=Map}) ->
    {reply, ok, S#serv{names=Map#{Name => Proc}}};
handle_call({disconnect, _Name, Pid}, _From, S=#serv{workers=W}) ->
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
handle_call({fwd, Name, Pid, Msg}, From, S=#serv{}) ->
    Pid ! {fwd, Name, From, Msg},
    {noreply, S};
handle_call(stop, _From, S=#serv{}) ->
    NewS = stop_server(S),
    {stop, {shutdown, stop}, ok, NewS};
handle_call({accepted, Pid, Sock}, _From, S=#serv{names=Names, dirs=Opts, workers=W,
                                                  acceptor=Pid}) ->
    Worker = start_linked_worker(Sock, Opts, Names),
    {reply, ok, S#serv{workers=W#{Worker => Sock}}};
handle_call(_, _From, State) ->
    {noreply, State}.

handle_cast(_Info, State) ->
    {noreply, State}.

handle_info({'EXIT', Acceptor, Reason}, S=#serv{acceptor=Acceptor}) ->
    {stop, {acceptor, Reason}, S};
handle_info({'EXIT', Worker, _}, S=#serv{workers=W}) ->
    Workers = maps:remove(Worker, W),
    {noreply, S#serv{workers=Workers}}.

terminate(_Reason, #serv{workers=W}) ->
    [exit(Pid, shutdown) || Pid <- maps:keys(W)],
    ok.

%%%%%%%%%%%%%%%%%%%%%
%%% ACCEPTOR LOOP %%%
%%%%%%%%%%%%%%%%%%%%%
acceptor(Parent, LSock) ->
    receive
        stop ->
            exit(normal)
    after 0 ->
        ok
    end,
    case gen_tcp:accept(LSock, ?ACCEPT_WAIT) of
        {ok, Sock} ->
            gen_tcp:controlling_process(Sock, Parent),
            gen_server:call(Parent, {accepted, self(), Sock}, infinity),
            acceptor(Parent, LSock);
        {error, timeout} ->
            acceptor(Parent, LSock);
        {error, Reason} ->
            error({accept, Reason})
    end.

%%%%%%%%%%%%%%%%%%%
%%% WORKER LOOP %%%
%%%%%%%%%%%%%%%%%%%
start_linked_worker(Sock, Opts, Names) ->
    %% TODO: stick into a supervisor
    Pid = proc_lib:spawn_link(fun() -> worker_init(Opts, Names) end),
    _ = gen_tcp:controlling_process(Sock, Pid),
    Pid ! {ready, Sock},
    Pid.

worker_init(Opts, Names) ->
    receive
        {ready, Sock} ->
            worker_dispatch(Names, #conn{sock=Sock, dirs=Opts})
    end.

worker_dispatch(Names, C=#conn{sock=Sock, dirs=Dirs, buf=Buf}) ->
    %% wrap the marker into a local one so that the responses
    %% can come to the proper connection process. There can be multiple
    %% TCP servers active for a single one and the responses must go
    %% to the right place.
    {ok, _Vsn, Msg, NewBuf} = next_msg(Sock, Buf),
    #{<<"sync">> := DirNames} = Dirs,
    case Msg of
        {revault, Marker, {peer, Dir, Attrs}} ->
            case lists:member(Dir, DirNames) of
                true ->
                    #{Dir := Name} = Names,
                    inet:setopts(Sock, [{active, 5}]),
                    revault_tcp:send_local(Name, {revault, {self(),Marker}, {peer, self(), Attrs}}),
                    worker_loop(Dir, C#conn{localname=Name, buf=NewBuf});
                false ->
                    gen_tcp:send(Sock, revault_tcp:wrap({revault, Marker, {error, eperm}})),
                    gen_tcp:close(Sock)
            end;
        _ ->
            Msg = {revault, internal, revault_data_wrapper:error(protocol)},
            gen_tcp:send(Sock, revault_tcp:wrap(Msg)),
            gen_tcp:close(Sock)
    end.

worker_loop(Dir, C=#conn{localname=Name, sock=Sock, buf=Buf0}) ->
    receive
        {fwd, _Name, From, Msg} ->
            Payload = revault_tcp:wrap(Msg),
            Res = gen_tcp:send(Sock, Payload),
            gen_server:reply(From, Res),
            worker_loop(Dir, C);
        disconnect ->
            gen_tcp:close(Sock),
            exit(normal);
        {pong, _} ->
            inet:setopts(Sock, [{active, 5}]),
            worker_loop(Dir, C);
        {tcp_passive, Sock} ->
            revault_fsm:ping(Name, self(), erlang:monotonic_time()),
            worker_loop(Dir, C);
        {tcp, Sock, Data} ->
            {Unwrapped, IncompleteBuf} = revault_tcp:unwrap_all(<<Buf0/binary, Data/binary>>),
            [revault_tcp:send_local(Name, {revault, {self(), Marker}, Msg})
             || {revault, Marker, Msg} <- Unwrapped],
            worker_loop(Dir, C#conn{buf = IncompleteBuf});
        {tcp_error, Sock, Reason} ->
            exit(Reason);
        {tcp_closed, Sock} ->
            exit(normal);
        Other ->
            error({unexpected, Other})
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
    case revault_tcp:unwrap(Buf) of
        {ok, Vsn, Msg, NewBuf} ->
            {ok, Vsn, Msg, NewBuf};
        {error, incomplete} ->
            case gen_tcp:recv(Sock, 0) of
                {ok, Bytes} ->
                    next_msg(Sock, <<Buf/binary, Bytes/binary>>);
                {error, Term} ->
                    {error, Term}
            end
    end.
