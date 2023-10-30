-module(revault_tls_client).
-export([start_link/2, start_link/3, update_dirs/2, stop/1]).
-export([peer/4, unpeer/2, send/4, reply/4]).
-export([callback_mode/0, init/1, handle_event/4, terminate/3]).
-behaviour(gen_statem).

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
start_link(Name, DirOpts) ->
    start_link(Name, DirOpts,
          [{delay_send, true}, {keepalive, true},
           {linger, {true, 0}}, {reuseaddr, true}]).

start_link(Name, DirOpts, TlsOpts) ->
    %% Ignore certs and stuff, assume the caller passes them in and things
    %% will fail otherwise.
    MandatoryOpts = [{mode, binary}, {packet, raw}, {active, 5}],
    AllTlsOpts = MandatoryOpts ++ TlsOpts,
    gen_statem:start_link(?CLIENT(Name), ?MODULE, {Name, DirOpts, AllTlsOpts}, []).

stop(Name) ->
    gen_statem:call(?CLIENT(Name), stop).

update_dirs(Name, DirOpts) ->
    gen_statem:call(?CLIENT(Name), {dirs, DirOpts}).

peer(Name, Peer, Auth, Payload) ->
    gen_statem:call(?CLIENT(Name), {connect, {Peer,Auth}, Payload}, infinity).

unpeer(Name, _Peer) ->
    gen_statem:call(?CLIENT(Name), disconnect, infinity).

send(Name, _Peer, Marker, Payload) ->
    gen_statem:call(?CLIENT(Name), {revault, Marker, Payload}, infinity).

reply(Name, _Peer, Marker, Payload) ->
    %% Ignore `Peer' because we should already be connected to one
    gen_statem:call(?CLIENT(Name), {revault, Marker, Payload}, infinity).

%%%%%%%%%%%%%%%%%%
%%% GEN_STATEM %%%
%%%%%%%%%%%%%%%%%%
callback_mode() -> handle_event_function.

%% This is where we vary from the server module by being connection-oriented
%% from the client-side rather than the server-side.
init({Name, DirOpts, TlsOpts}) ->
    {ok, disconnected, #client{name=Name, dirs=DirOpts, opts=TlsOpts}}.

handle_event({call, From}, {dirs, DirOpts}, _State, Data) ->
    %% TODO: maybe force disconnect if the options changed
    {keep_state, Data#client{dirs=DirOpts},
     [{reply, From, ok}]};
handle_event({call, From}, {connect, {Peer,Auth}, Msg}, disconnected, Data) ->
    case connect(Data, Peer, Auth) of
        {ok, ConnData} ->
            NewData = case introspect(Msg) of
                {peer, Dir, Attrs} ->
                    maybe_add_ctx(Attrs, ConnData#client{dir=Dir});
                _ ->
                    ConnData
            end,
            handle_event({call, From}, Msg, connected, NewData);
        {error, Reason} ->
            {keep_state_and_data, [{reply, From, {error, Reason}}]}
    end;
handle_event({call, From}, disconnect, disconnected, Data) ->
    {keep_state, Data, [{reply, From, ok}]};
handle_event({call, From}, disconnect, connected, Data=#client{sock=Sock}) ->
    ssl:close(Sock),
    otel_ctx:clear(),
    {next_state, disconnected, Data#client{sock=undefined, dir=undefined},
     [{reply, From, ok}]};
handle_event({call, From}, Msg, disconnected, Data=#client{peer=Peer, auth=Auth}) ->
    case connect(Data, Peer, Auth) of
        {ok, TmpData} ->
            NewData = start_span(<<"tls_client">>, TmpData),
            set_attributes(?attrs(NewData)),
            handle_event({call, From}, Msg, connected, NewData);
        {error, Reason} ->
            %% TODO: backoffs & retry, maybe add idle -> disconnected -> connected
            exit({error, Reason})
    end;
handle_event({call, From}, {revault, Marker, _Msg}=Msg, connected, TmpData=#client{sock=Sock}) ->
    Data = start_span(<<"fwd">>, TmpData),
    set_attributes([{<<"msg">>, ?str(type(Msg))} | ?attrs(Data)]),
    Payload = revault_tls:wrap(Msg),
    Res = ssl:send(Sock, Payload),
    NewData = end_span(Data),
    case Res of
        ok ->
            {next_state, connected, Data, [{reply, From, {ok, Marker}}]};
        {error, Reason} ->
            _ = ssl:close(Sock),
            otel_ctx:clear(),
            {next_state, disconnected, NewData#client{sock=undefined, dir=undefined},
             [{reply, From, {error, Reason}}]}
    end;
handle_event(info, {ssl_passive, Sock}, connected, Data=#client{name=Name, sock=Sock}) ->
    revault_fsm:ping(Name, self(), erlang:monotonic_time(millisecond)),
    {keep_state, Data, []};
handle_event(info, {pong, T}, connected, Data=#client{sock=Sock, active=Active}) ->
    Now = erlang:monotonic_time(millisecond),
    NewActive = case Now - T > ?BACKOFF_THRESHOLD of
        true -> max(Active div 2, ?MIN_ACTIVE);
        false -> Active * 2
    end,
    ssl:setopts(Sock, [{active, NewActive}]),
    {keep_state, Data#client{active=NewActive}, []};
handle_event(info, {ssl, Sock, Bin}, connected, Data=#client{name=Name, sock=Sock, buf=Buf0}) ->
    TmpData = maybe_start_unique_span(<<"recv">>, Data#client.recv, Data#client{recv=true}),
    Buf1 = revault_tls:buf_add(Bin, Buf0),
    {Unwrapped, IncompleteBuf} = revault_tls:unwrap_all(Buf1),
    [revault_tls:send_local(Name, Msg) || Msg <- Unwrapped],
    NewData = case length(Unwrapped) of
        0 ->
            TmpData;
        MsgCount ->
            set_attributes([{<<"msgs">>, MsgCount},
                            {<<"buf">>, revault_tls:buf_size(Buf1)},
                            {<<"buf_trail">>, revault_tls:buf_size(IncompleteBuf)}
                            | ?attrs(TmpData)]),
            end_span(TmpData#client{recv=false})
    end,
    {next_state, connected, NewData#client{buf=IncompleteBuf}};
handle_event(info, {ssl_error, Sock, _Reason}, connected, Data=#client{sock=Sock}) ->
    %% TODO: Log
    otel_ctx:clear(),
    {next_state, disconnected, Data#client{sock=undefined, dir=undefined}};
handle_event(info, {pong, _}, disconnected, Data) ->
    {keep_state, Data};
handle_event(info, {ssl_closed, Sock}, connected, Data=#client{sock=Sock}) ->
    otel_ctx:clear(),
    {next_state, disconnected, Data#client{sock=undefined, dir=undefined}};
handle_event(info, {ssl_closed, _Sock}, connected, Data=#client{}) ->
    %% unrelated message from an old connection
    {next_state, connected, Data};
handle_event(info, {ssl_closed, _Sock}, disconnected, Data=#client{}) ->
    {next_state, disconnected, Data#client{sock=undefined, dir=undefined}}.

terminate(_Reason, _State, _Data) ->
    ok.

%%%%%%%%%%%%%%%
%%% HELPERS %%%
%%%%%%%%%%%%%%%
connect(Data=#client{dirs=Dirs, sock=undefined, opts=Opts}, Peer, Auth) when Peer =/= undefined ->
    #{<<"peers">> := #{Peer := #{<<"url">> := Url,
                                 <<"auth">> := #{<<"type">> := <<"tls">>,
                                                 <<"certfile">> := Cert,
                                                 <<"keyfile">> := Key,
                                                 <<"peer_certfile">> := ServerCert}}}} = Dirs,
    PinOpts = revault_tls:pin_certfile_opts_client(ServerCert) ++
              [{certfile, Cert}, {keyfile, Key}],
    {Host, Port} = parse_url(Url),
    case ssl:connect(Host, Port, Opts++PinOpts) of
        {ok, Sock} ->
            {ok, Data#client{sock=Sock, dir=undefined, peer=Peer, auth=Auth}};
        {error, Reason} ->
            {error, Reason}
    end;
connect(Data=#client{sock=Sock}, _, _) when Sock =/= undefined ->
    {ok, Data}.

-spec parse_url(binary()) -> {string(), 0..65535}.
parse_url(Url) when is_binary(Url) ->
    [HostBin, PortBin] = binary:split(Url, <<":">>),
    Host = [_|_] = unicode:characters_to_list(HostBin),
    Port = port_range(binary_to_integer(PortBin)),
    {Host, Port}.

%% please gradualizer type conversions with this stuff...
-spec port_range(integer()) -> 0..65535.
port_range(N) when N >= 0, N =< 65535 -> N.

attrs(#client{peer=Peer, dir=Dir, sock=S}) ->
    [{<<"peer">>, Peer}, {<<"dir">>, Dir} | sock_attrs(S) ++ pid_attrs()].

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


start_span(SpanName, Data=#client{ctx=Stack}) ->
    SpanCtx = otel_tracer:start_span(?current_tracer, SpanName, #{}),
    Ctx = otel_tracer:set_current_span(otel_ctx:get_current(), SpanCtx),
    Token = otel_ctx:attach(Ctx),
    set_attributes(attrs(Data)),
    Data#client{ctx=[{SpanCtx,Token}|Stack]}.

maybe_start_unique_span(SpanName, false, Data) ->
    start_span(SpanName, Data);
maybe_start_unique_span(_, true, Data) ->
    Data.

maybe_add_ctx(#{ctx:=SpanCtx}, Data=#client{ctx=Stack}) ->
    Ctx = otel_tracer:set_current_span(otel_ctx:get_current(), SpanCtx),
    Token = otel_ctx:attach(Ctx),
    set_attributes(attrs(Data)),
    Data#client{ctx=[{SpanCtx,Token}|Stack]};
maybe_add_ctx(_, Data) ->
    Data.

set_attributes(Attrs) ->
    SpanCtx = otel_tracer:current_span_ctx(otel_ctx:get_current()),
    otel_span:set_attributes(SpanCtx, Attrs).

end_span(Data=#client{ctx=[{SpanCtx,Token}|Stack]}) ->
    _ = otel_tracer:set_current_span(otel_ctx:get_current(),
                                     otel_span:end_span(SpanCtx, undefined)),
    otel_ctx:detach(Token),
    Data#client{ctx=Stack}.

type({revault, _, T}) when is_tuple(T) ->
    element(1,T);
type(_) ->
    undefined.

%% TODO: make this unpacking business cleaner, don't like a
%%       pack/unpack just for introspection breaking the abstraction
introspect({revault, _Marker, Payload}) ->
    revault_tls:unpack(Payload).
