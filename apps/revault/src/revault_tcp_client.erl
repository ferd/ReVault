%% TODO: wrap caller-side events into calls, within which the failures
%% and retries are attempted. Without that synchronous mode, error-handling
%% makes no sense.
-module(revault_tcp_client).
-export([start_link/2, start_link/3, update_dirs/2, stop/1]).
-export([callback_mode/0, init/1, handle_event/4, terminate/3]).
-behaviour(gen_statem).

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
    gen_statem:start_link(?CLIENT(Name), ?MODULE, {DirOpts, AllTcpOpts}, []).

stop(Name) ->
    gen_statem:call(?CLIENT(Name), stop).

update_dirs(Name, DirOpts) ->
    gen_statem:call(?CLIENT(Name), {dirs, DirOpts}).

%%%%%%%%%%%%%%%%%%
%%% GEN_STATEM %%%
%%%%%%%%%%%%%%%%%%
callback_mode() -> handle_event_function.

%% This is where we vary from the server module by being connection-oriented
%% from the client-side rather than the server-side.
init({DirOpts, TcpOpts}) ->
    {ok, disconnected, #client{dirs=DirOpts, opts=TcpOpts}}.

handle_event({call, From}, {dirs, DirOpts}, _State, Data) ->
    %% TODO: maybe force disconnect if the options changed
    {keep_state, Data#client{dirs=DirOpts},
     [{reply, From, ok}]};
handle_event(info, Msg, disconnected, Data) ->
    case connect(Data, Msg) of
        {ok, NewData} ->
            handle_event(info, Msg, connected, NewData);
        {error, Reason} ->
            %% TODO: backoffs & retry, maybe add idle -> disconnected -> connected
            exit({error, Reason})
    end;
handle_event(info, {revault, _From, Msg}, connected, Data=#client{sock=Sock}) ->
    Payload = revault_tcp:wrap(Msg),
    case gen_tcp:send(Sock, Payload) of
        ok ->
            {next_state, connected, Data};
        {error, Reason} ->
            %% TODO: backoffs & retry, maybe add idle -> disconnected -> connected
            exit({error, Reason})
    end;
handle_event(info, {tcp, Sock, Bin}, connected, Data=#client{sock=Sock, buf=Buf0}) ->
    inet:setopts(Sock, [{active, once}]),
    case revault_tcp:unwrap(TmpBuf = <<Buf0/binary, Bin/binary>>) of
        {error, incomplete} ->
            {next_state, connected, Data#client{buf=TmpBuf}};
        {ok, ?VSN, Msg, NewBuf} ->
            #client{dir=Dir} = Data,
            revault_tcp:send_local(Dir, Msg),
            {next_state, connected, Data#client{buf=NewBuf}}
    end;
handle_event(info, {tcp_error, Sock, _Reason}, connected, Data=#client{sock=Sock}) ->
    %% TODO: Log
    {next_state, disconnected, Data#client{sock=undefined}};
handle_event(info, {tcp_closed, Sock}, connected, Data=#client{sock=Sock}) ->
    {next_state, disconnected, Data#client{sock=undefined}}.

terminate(_Reason, _State, _Data) ->
    ok.

%%%%%%%%%%%%%%%
%%% HELPERS %%%
%%%%%%%%%%%%%%%
connect(Data=#client{dirs=Dirs, sock=undefined, opts=Opts}, {session, [Dir|_]}) ->
    #{Dir := {Url, Port}} = Dirs,
    case gen_tcp:connect(Url, Port, Opts) of
        {ok, Sock} ->
            {ok, Data#client{sock=Sock, dir=Dir}};
        {error, Reason} ->
            {error, Reason}
    end;
connect(Data=#client{dir=Dir, dirs=Dirs, sock=undefined, opts=Opts}, _) ->
    #{Dir := {Url, Port}} = Dirs,
    case gen_tcp:connect(Url, Port, Opts) of
        {ok, Sock} ->
            {ok, Data#client{sock=Sock}};
        {error, Reason} ->
            {error, Reason}
    end;
connect(Data=#client{sock=Sock}, _) when Sock =/= undefined ->
    {ok, Data}.
