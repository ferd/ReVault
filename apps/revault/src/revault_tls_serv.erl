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
%% shared callbacks
-export([start_link/1, start_link/2, update_dirs/1, map/2, stop/0]).
%% scoped callbacks
-export([accept_peer/3, unpeer/3, reply/5]).
%% behavior callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-behaviour(gen_server).

-include("revault_tls.hrl").
-include_lib("opentelemetry_api/include/otel_tracer.hrl").
-define(str(T), unicode:characters_to_binary(io_lib:format("~tp", [T]))).
-define(attrs(T), [{<<"module">>, ?MODULE},
                   {<<"function">>, ?FUNCTION_NAME},
                   {<<"line">>, ?LINE},
                   {<<"node">>, node()},
                   {<<"pid">>, ?str(self())}
                   | attrs(T)]).


%%%%%%%%%%%%%%%%%%
%%% PUBLIC API %%%
%%%%%%%%%%%%%%%%%%
start_link(DirOpts) ->
    start_link(DirOpts,
          [{delay_send, true}, {keepalive, true},
           {linger, {true, 0}}, {reuseaddr, true}]).

start_link(DirOpts, TlsOpts) ->
    MandatoryOpts = [{mode, binary}, {packet, raw}, {active, false}],
    AllTlsOpts = MandatoryOpts ++ TlsOpts,
    gen_server:start_link(?SERVER, ?MODULE, {DirOpts, AllTlsOpts}, []).

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
init({#{<<"server">> := #{<<"auth">> := #{<<"tls">> := DirOpts}}}, TlsOpts}) ->
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
                    Parent = self(),
                    Acceptor = proc_lib:spawn_link(fun() -> acceptor(Parent, LSock) end),
                    {ok, #serv{dirs=DirOpts, opts=TlsOpts, sock=LSock, acceptor=Acceptor}}
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
    case ssl:transport_accept(LSock, ?ACCEPT_WAIT) of
        {error, _Reason} -> % don't crash on bad TLS, this is super common
            acceptor(Parent, LSock);
        {ok, HSock} ->
            case ssl:handshake(HSock, ?HANDSHAKE_WAIT) of
                {error, _Reason} ->
                    ssl:close(HSock),
                    acceptor(Parent, LSock);
                {ok, Sock} ->
                    ssl:controlling_process(Sock, Parent),
                    gen_server:call(Parent, {accepted, self(), Sock}, infinity),
                    acceptor(Parent, LSock)
            end
    end.

%%%%%%%%%%%%%%%%%%%
%%% WORKER LOOP %%%
%%%%%%%%%%%%%%%%%%%
start_linked_worker(Sock, Opts, Names) ->
    %% TODO: stick into a supervisor
    Pid = spawn_link(fun() -> worker_init(Opts, Names) end),
    _ = ssl:controlling_process(Sock, Pid),
    Pid ! {ready, Sock},
    Pid.

worker_init(Opts, Names) ->
    receive
        {ready, Sock} ->
            %% TODO: Figure out the certificate to know which directories are accessible
            %%       to this cert; remove the unaccessible dirs from the config.
            {ok, Cert} = ssl:peercert(Sock),
            NewOpts = match_cert(Cert, Opts),
            worker_dispatch(Names, #conn{sock=Sock, dirs=NewOpts})
    end.

worker_dispatch(Names, C=#conn{sock=Sock, dirs=Dirs, buf=Buf}) ->
    %% wrap the marker into a local one so that the responses
    %% can come to the proper connection process. There can be multiple
    %% TLS servers active for a single one and the responses must go
    %% to the right place.
    {ok, ?VSN, Msg, NewBuf} = next_msg(Sock, Buf),
    #{<<"authorized">> := #{<<"sync">> := DirNames}} = Dirs,
    case Msg of
        {revault, Marker, {peer, Dir, Attrs}} ->
            Cn = maybe_add_ctx(Attrs, C),
            case lists:member(Dir, DirNames) of
                true ->
                    #{Dir := Name} = Names,
                    ssl:setopts(Sock, [{active, once}]),
                    revault_tls:send_local(Name, {revault, {self(),Marker},
                                                    {peer, self(), Attrs}}),
                    worker_loop(Dir, Cn#conn{localname=Name, buf=NewBuf});
                false ->
                    ssl:send(Sock, revault_tls:wrap({revault, Marker, {error, eperm}})),
                    ssl:close(Sock)
            end;
        _ ->
            Msg = {revault, internal, revault_data_wrapper:error(protocol)},
            ssl:send(Sock, revault_tls:wrap(Msg)),
            ssl:close(Sock)
    end.

worker_loop(Dir, C=#conn{localname=Name, sock=Sock, buf=Buf0}) ->
    receive
        {fwd, _Name, From, Msg} ->
            ?with_span(<<"fwd">>, #{attributes => [{<<"msg">>, ?str(type(Msg))} | ?attrs(C)]},
                       fun(_SpanCtx) ->
                            Payload = revault_tls:wrap(Msg),
                            Res = ssl:send(Sock, Payload),
                            gen_server:reply(From, Res)
                       end),
            worker_loop(Dir, C);
        disconnect ->
            ?with_span(<<"disconnect">>, #{attributes => ?attrs(C)},
                       fun(_SpanCtx) -> ssl:close(Sock) end),
            exit(normal);
        {ssl, Sock, Data} ->
            TmpC = start_span(<<"recv">>, C),
            ssl:setopts(Sock, [{active, once}]),
            {Unwrapped, IncompleteBuf} = unwrap_all(<<Buf0/binary, Data/binary>>),
            [revault_tls:send_local(Name, {revault, {self(), Marker}, Msg})
             || {revault, Marker, Msg} <- Unwrapped],
            set_attributes([{<<"msgs">>, length(Unwrapped)},
                            {<<"buf">>, byte_size(IncompleteBuf)} | ?attrs(C)]),
            C = end_span(TmpC),
            worker_loop(Dir, C#conn{buf = IncompleteBuf});
        {ssl_error, Sock, Reason} ->
            exit(Reason);
        {ssl_closed, Sock} ->
            exit(normal)
    end.

unwrap_all(Buf) ->
    unwrap_all(Buf, []).

unwrap_all(Buf, Acc) ->
    case revault_tls:unwrap(Buf) of
        {error, incomplete} ->
            {lists:reverse(Acc), Buf};
        {ok, ?VSN, Payload, NewBuf} ->
            unwrap_all(NewBuf, [Payload|Acc])
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

%% TODO: cache and pre-load certificates from disk to avoid the
%% reading and decoding cost every time.
match_cert(Cert, Opts = #{<<"authorized">> := Entries}) ->
    case lists:search(fun({_, #{<<"certfile">> := File}}) ->
                              Cert =:= decode_cert(File)
                      end, maps:to_list(Entries)) of
        {value, {_PeerName, SubMap}} ->
            Opts#{<<"authorized">> => SubMap};
        false ->
            Opts#{<<"authorized">> => #{<<"sync">> => []}}
    end.

decode_cert(FileName) ->
    %% assume the cert is already DER encoded.
    {ok, Cert} = file:read_file(FileName),
    public_key:pkix_encode('OTPCertificate',
                           tak:peer_cert(tak:pem_to_cert_chain(Cert)),
                           otp).

attrs(#conn{localname=Dir, sock=S}) ->
    [{<<"dir">>, Dir} | sock_attrs(S) ++ pid_attrs()].

pid_attrs() ->
    PidInfo = process_info(
        self(),
        [memory, message_queue_len, heap_size,
         total_heap_size, reductions, garbage_collection]
    ),
    [{<<"pid">>, ?str(self())},
     {<<"pid.memory">>, proplists:get_value(memory, PidInfo)},
     {<<"pid.message_queue_len">>, proplists:get_value(message_queue_len, PidInfo)},
     {<<"pid.heap_size">>, proplists:get_value(heap_size, PidInfo)},
     {<<"pid.total_heap_size">>, proplists:get_value(total_heap_size, PidInfo)},
     {<<"pid.reductions">>, proplists:get_value(reductions, PidInfo)},
     {<<"pid.minor_gcs">>,
       proplists:get_value(minor_gcs,
                           proplists:get_value(garbage_collection, PidInfo))}
    ].

sock_attrs(undefined) ->
    [];
sock_attrs(Sock) ->
    case ssl:getstat(Sock, [recv_cnt, recv_oct, send_cnt, send_pend, send_oct]) of
        {ok, SockStats} ->
            [{<<"sock.", (atom_to_binary(K))/binary>>, V} || {K, V} <- SockStats];
        {error, _} ->
            []
    end.

start_span(SpanName, Data=#conn{ctx=Stack}) ->
    SpanCtx = otel_tracer:start_span(?current_tracer, SpanName, #{}),
    Ctx = otel_tracer:set_current_span(otel_ctx:get_current(), SpanCtx),
    Token = otel_ctx:attach(Ctx),
    set_attributes(attrs(Data)),
    Data#conn{ctx=[{SpanCtx,Token}|Stack]}.

maybe_add_ctx(#{ctx:=SpanCtx}, Data=#conn{ctx=Stack}) ->
    Ctx = otel_tracer:set_current_span(otel_ctx:get_current(), SpanCtx),
    Token = otel_ctx:attach(Ctx),
    set_attributes(attrs(Data)),
    Data#conn{ctx=[{SpanCtx,Token}|Stack]};
maybe_add_ctx(_, Data) ->
    Data.

set_attributes(Attrs) ->
    SpanCtx = otel_tracer:current_span_ctx(otel_ctx:get_current()),
    otel_span:set_attributes(SpanCtx, Attrs).

end_span(Data=#conn{ctx=[{SpanCtx,Token}|Stack]}) ->
    _ = otel_tracer:set_current_span(otel_ctx:get_current(),
                                     otel_span:end_span(SpanCtx, undefined)),
    otel_ctx:detach(Token),
    Data#conn{ctx=Stack}.

type({revault, _, T}) when is_tuple(T) ->
    element(1,T);
type(_) ->
    undefined.
