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
-export([start_link/2, start_link/3, update_dirs/2, stop/1]).
-export([reply/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-behaviour(gen_server).

-include("revault_tcp.hrl").

%%%%%%%%%%%%%%%%%%
%%% PUBLIC API %%%
%%%%%%%%%%%%%%%%%%
start_link(Name, DirOpts) ->
    start_link(Name, DirOpts,
          [{delay_send, true}, {keepalive, true},
           {linger, {true, 0}}, {reuseaddr, true}]).

start_link(Name, DirOpts, TcpOpts) ->
    MandatoryOpts = [{mode, binary}, {packet, raw}, {active, false}],
    AllTcpOpts = MandatoryOpts ++ TcpOpts,
    gen_server:start_link(?SERVER(Name), ?MODULE, {Name, DirOpts, AllTcpOpts}, []).

stop(Name) ->
    gen_server:call(?SERVER(Name), stop).

update_dirs(Name, DirOpts) ->
    gen_server:call(?SERVER(Name), {dirs, DirOpts}).

reply(Name, _Dir, {Pid,Marker}, Payload) ->
    gen_server:call(?SERVER(Name), {fwd, Pid, {revault, Marker, Payload}}, infinity).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% GEN_SERVER / MANAGEMENT %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% We can use a single acceptor process loop because we rather expect
%% the heavy work to be done by the sync servers and the worker loops,
%% not the acceptor. It also simplifies the handling of auth and
%% permissions.
% {server => auth => none => sync
init({Name, #{<<"server">> := #{<<"auth">> := #{<<"none">> := DirOpts}}}, TcpOpts}) ->
    #{<<"port">> := Port, <<"status">> := Status} = DirOpts,
    case Status of
        enabled ->
            case gen_tcp:listen(Port, TcpOpts) of
                {error, Reason} ->
                    {stop, {listen,Reason}};
                {ok, LSock} ->
                    process_flag(trap_exit, true),
                    self() ! accept,
                    {ok, #serv{name=Name, dirs=DirOpts, opts=TcpOpts, sock=LSock}}
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
    case gen_tcp:accept(LSock, ?ACCEPT_WAIT) of
        {ok, Sock} ->
            Worker = start_linked_worker(Name, Sock, Opts),
            self() ! accept,
            {noreply, S#serv{workers=W#{Worker => Sock}}};
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
    _ = gen_tcp:controlling_process(Sock, Pid),
    Pid ! {ready, Sock},
    Pid.

worker_init(LocalName, Opts) ->
    receive
        {ready, Sock} ->
            worker_dispatch(#conn{localname=LocalName, sock=Sock, dirs=Opts})
    end.

worker_dispatch(C=#conn{localname=Name, sock=Sock, dirs=Dirs, buf=Buf}) ->
    %% TODO: wrap the marker into a local one so that the responses
    %% can come to the proper connection process. There can be multiple
    %% TCP servers active for a single one and the responses must go
    %% to the right place.
    {ok, ?VSN, Msg, NewBuf} = next_msg(Sock, Buf),
    #{<<"sync">> := DirNames} = Dirs,
    ct:pal("Msg: ~p", [Msg]),
    case Msg of
        {revault, Marker, {peer, Dir}} ->
            case lists:member(Dir, DirNames) of
                true ->
                    inet:setopts(Sock, [{active, once}]),
                    revault_tcp:send_local(Name, {revault, {self(),Marker}, {peer, self()}}),
                    worker_loop(Dir, C#conn{buf=NewBuf});
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
        {revault, _From, Msg} ->
            Payload = revault_tcp:wrap(Msg),
            gen_tcp:send(Sock, Payload),
            worker_loop(Dir, C);
        {fwd, From, Msg} ->
            Payload = revault_tcp:wrap(Msg),
            Res = gen_tcp:send(Sock, Payload),
            gen_server:reply(From, Res),
            worker_loop(Dir, C);
        {tcp, Sock, Data} ->
            inet:setopts(Sock, [{active, once}]),
            case revault_tcp:unwrap(<<Buf0/binary, Data/binary>>) of
                {error, incomplete} ->
                    worker_loop(Dir, C#conn{buf = <<Buf0/binary, Data/binary>>});
                {ok, ?VSN, Msg, NewBuf} ->
                    revault_tcp:send_local(Name, Msg),
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
