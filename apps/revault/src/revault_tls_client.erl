-module(revault_tls_client).
-export([start_link/2, start_link/3, update_dirs/2, stop/1]).
-export([peer/4, unpeer/2, send/4, reply/4]).
-export([callback_mode/0, init/1, handle_event/4, terminate/3]).
-behaviour(gen_statem).

-include("revault_tls.hrl").
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
    MandatoryOpts = [{mode, binary}, {packet, raw}, {active, once}],
    AllTlsOpts = MandatoryOpts ++ TlsOpts,
    gen_statem:start_link(?CLIENT(Name), ?MODULE, {Name, DirOpts, AllTlsOpts}, [{debug, [trace]}]).

stop(Name) ->
    gen_statem:call(?CLIENT(Name), stop).

update_dirs(Name, DirOpts) ->
    gen_statem:call(?CLIENT(Name), {dirs, DirOpts}).

peer(Name, Dir, Auth, Payload) ->
    gen_statem:call(?CLIENT(Name), {connect, {Dir,Auth}, Payload}, infinity).

unpeer(Name, _Dir) ->
    gen_statem:call(?CLIENT(Name), disconnect, infinity).

send(Name, _Dir, Marker, Payload) ->
    gen_statem:call(?CLIENT(Name), {revault, Marker, Payload}, infinity).

reply(Name, _Dir, Marker, Payload) ->
    %% Ignore `Dir' because we should already be connected to one
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
handle_event({call, From}, {connect, {Dir,Auth}, Msg}, disconnected, Data) ->
    case connect(Data, Dir, Auth) of
        {ok, NewData} ->
            handle_event({call, From}, Msg, connected, NewData);
        {error, Reason} ->
            {keep_state_and_data, [{reply, From, {error, Reason}}]}
    end;
handle_event({call, From}, disconnect, disconnected, Data) ->
    {keep_state, Data, [{reply, From, ok}]};
handle_event({call, From}, disconnect, connected, Data=#client{sock=Sock}) ->
    ssl:close(Sock),
    {next_state, disconnected, Data#client{sock=undefined},
     [{reply, From, ok}]};
handle_event({call, From}, Msg, disconnected, Data=#client{dir=Dir, auth=Auth}) ->
    case connect(Data, Dir, Auth) of
        {ok, NewData} ->
            handle_event({call, From}, Msg, connected, NewData);
        {error, Reason} ->
            %% TODO: backoffs & retry, maybe add idle -> disconnected -> connected
            exit({error, Reason})
    end;
handle_event({call, From}, {revault, Marker, _Msg}=Msg, connected, Data=#client{sock=Sock}) ->
    Payload = revault_tls:wrap(Msg),
    case ssl:send(Sock, Payload) of
        ok ->
            {next_state, connected, Data, [{reply, From, {ok, Marker}}]};
        {error, Reason} ->
            _ = ssl:close(Sock),
            {next_state, disconnected, Data#client{sock=undefined},
             [{reply, From, {error, Reason}}]}
    end;
handle_event(info, {ssl, Sock, Bin}, connected, Data=#client{sock=Sock, buf=Buf0}) ->
    ssl:setopts(Sock, [{active, once}]),
    case revault_tls:unwrap(TmpBuf = <<Buf0/binary, Bin/binary>>) of
        {error, incomplete} ->
            {next_state, connected, Data#client{buf=TmpBuf}};
        {ok, ?VSN, Msg, NewBuf} ->
            #client{name=Name} = Data,
            revault_tls:send_local(Name, Msg),
            {next_state, connected, Data#client{buf=NewBuf}}
    end;
handle_event(info, {ssl_error, Sock, _Reason}, connected, Data=#client{sock=Sock}) ->
    %% TODO: Log
    {next_state, disconnected, Data#client{sock=undefined}};
handle_event(info, {ssl_closed, Sock}, connected, Data=#client{sock=Sock}) ->
    {next_state, disconnected, Data#client{sock=undefined}}.

terminate(_Reason, _State, _Data) ->
    ok.

%%%%%%%%%%%%%%%
%%% HELPERS %%%
%%%%%%%%%%%%%%%
connect(Data=#client{dirs=Dirs, sock=undefined, opts=Opts}, Dir, Auth) when Dir =/= undefined ->
    #{<<"peers">> := #{Dir := #{<<"url">> := Url,
                                <<"auth">> := #{<<"type">> := <<"tls">>,
                                                <<"certfile">> := Cert,
                                                <<"keyfile">> := Key,
                                                <<"peer_certfile">> := ServerCert}}}} = Dirs,
    PinOpts = revault_tls:pin_certfile_opts(ServerCert) ++
              [{certfile, Cert}, {keyfile, Key}],
    [Host, PortBin] = binary:split(Url, <<":">>),
    case ssl:connect(unicode:characters_to_list(Host),
                     binary_to_integer(PortBin),
                     Opts++PinOpts) of
        {ok, Sock} ->
            {ok, Data#client{sock=Sock, dir=Dir, auth=Auth}};
        {error, Reason} ->
            {error, Reason}
    end;
connect(Data=#client{sock=Sock}, _, _) when Sock =/= undefined ->
    {ok, Data}.
