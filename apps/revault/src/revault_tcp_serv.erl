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
-export([start/2, start/3, update_dirs/2, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-behaviour(gen_server).

-define(VSN, 1).
-define(ACCEPT_WAIT, 100).
-record(serv, {dirs, opts, sock, workers=#{}}).
-record(conn, {sock, dirs, buf = <<>>}).

%%%%%%%%%%%%%%%%%%
%%% PUBLIC API %%%
%%%%%%%%%%%%%%%%%%
start(Name, DirOpts) ->
    start(Name, DirOpts,
          [{delay_send, true}, {keepalive, true},
           {linger, {true, 0}}, {reuseaddr, true}]).

start(Name, DirOpts, TcpOpts) ->
    MandatoryOpts = [{mode, binary}, {packet, raw}, {active, false}],
    AllTcpOpts = MandatoryOpts ++ TcpOpts,
    gen_server:start_link({local, Name}, ?MODULE, {DirOpts, AllTcpOpts}, []).

stop(Name) ->
    gen_server:call(Name, stop).

update_dirs(Name, DirOpts) ->
    gen_server:call(Name, {dirs, DirOpts}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% GEN_SERVER / MANAGEMENT %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% We can use a single acceptor process loop because we rather expect
%% the heavy work to be done by the sync servers and the worker loops,
%% not the acceptor. It also simplifies the handling of auth and
%% permissions.
init({DirOpts = #{<<"port">> := Port, <<"status">> := enabled}, TcpOpts}) ->
    case gen_tcp:listen(Port, TcpOpts) of
        {error, Reason} ->
            {stop, {listen,Reason}};
        {ok, LSock} ->
            process_flag(trap_exit, true),
            self() ! accept,
            {ok, #serv{dirs=DirOpts, opts=TcpOpts, sock=LSock}}
    end;
init(_) ->
    {stop, disabled}.

handle_call({dirs, DirOpts}, _From, S=#serv{}) ->
    %% TODO: handle port change
    %% TODO: handle status: disabled
    {reply, ok, S#serv{dirs=DirOpts}};
handle_call(stop, _From, S=#serv{}) ->
    NewS = stop_server(S),
    {stop, {shutdown, stop}, ok, NewS};
handle_call(_, _From, State) ->
    {noreply, State}.

handle_cast(_Info, State) ->
    {noreply, State}.

handle_info(accept, S=#serv{sock=LSock, dirs=Opts, workers=W}) ->
    case gen_tcp:accept(LSock, ?ACCEPT_WAIT) of
        {ok, Sock} ->
            Worker = start_linked_worker(Sock, Opts),
            self() ! accept,
            {ok, S#serv{workers=W#{Worker => Sock}}};
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
start_linked_worker(Sock, Opts) ->
    %% TODO: stick into a supervisor
    Pid = spawn_link(fun() -> worker_init(Opts) end),
    _ = gen_tcp:controlling_process(Sock, Pid),
    Pid ! {ready, Sock},
    Pid.

worker_init(Opts) ->
    receive
        {ready, Sock} ->
            worker_dispatch(#conn{sock=Sock, dirs=Opts})
    end.

worker_dispatch(C=#conn{sock=Sock, dirs=Dirs, buf=Buf}) ->
    {ok, ?VSN, Msg, NewBuf} = next_msg(Sock, Buf),
    #{<<"sync">> := DirNames} = Dirs,
    case Msg of
        {session, [Dir|_]} ->
            case lists:member(Dir, DirNames) of
                true ->
                    inet:setopts(Sock, [{active, once}]),
                    worker_loop(Dir, C#conn{buf=NewBuf});
                false ->
                    gen_tcp:send(Sock, to_msg({error, eperm})),
                    gen_tcp:close(Sock)
            end;
        _ ->
            gen_tcp:send(Sock, to_msg({error, protocol})),
            gen_tcp:close(Sock)
    end.

worker_loop(Dir, C=#conn{sock=Sock, buf=Buf0}) ->
    receive
        {revault, _From, Msg} ->
            Payload = to_msg(Msg),
            gen_tcp:send(Sock, Payload),
            worker_loop(Dir, C);
        {tcp, Sock, Data} ->
            inet:setopts(Sock, [{active, once}]),
            case unwrap(<<Buf0/binary, Data/binary>>) of
                {error, incomplete} ->
                    worker_loop(Dir, C#conn{buf = <<Buf0/binary, Data/binary>>});
                {ok, ?VSN, Msg, NewBuf} ->
                    send_local(Dir, Msg),
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

to_msg({session, _Dir} = Msg) -> wrap(Msg);
to_msg(ask) -> wrap(ask);
to_msg({error, _} = Msg) -> wrap(Msg);
to_msg(manifest = Msg) -> wrap(Msg);
to_msg({manifest, _Data} = Msg) -> wrap(Msg);
to_msg({file, _Path, _Meta, _Bin} = Msg) -> wrap(Msg);
to_msg({fetch, _Path} = Msg) -> wrap(Msg);
to_msg(sync_complete = Msg) -> wrap(Msg);
to_msg({conflict_file, _WorkPath, _Path, _Meta, _Bin} = Msg) -> wrap(Msg).


wrap(Msg) ->
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

next_msg(Sock, Buf) ->
    case unwrap(Buf) of
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

send_local(Name, Payload) ->
    From = self(),
    gproc:send({n, l, {revault_sync_fsm, Name}},
               {revault, From, Payload}).
