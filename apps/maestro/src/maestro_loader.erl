-module(maestro_loader).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-define(RELOAD_INTERVAL, timer:minutes(5)).

-export([start_link/0, status/0]).
-export([init/1,
         handle_call/3, handle_cast/2, handle_info/2, handle_continue/2,
         terminate/2]).
-record(state, {
          cfg_path :: file:filename_all(),
          cfg :: maestro_cfg:t() | undefined,
          timer :: undefined | reference()
        }).

%%%%%%%%%%%%%%%%%%
%%% PUBLIC API %%%
%%%%%%%%%%%%%%%%%%
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

status() ->
    gen_server:call(?MODULE, status, 10000).

%%%%%%%%%%%%%%%%%
%%% CALLBACKS %%%
%%%%%%%%%%%%%%%%%
init([]) ->
    CfgPath = maestro_cfg:config_path(),
    {ok, #state{cfg_path = CfgPath}, {continue, load_config}}.

handle_call(status, _From, State=#state{cfg=Current, cfg_path=Path}) ->
    case maestro_cfg:parse_file(Path) of
        {ok, Current} ->
            {reply, current, State};
        {ok, _Other} ->
            {reply, outdated, State};
        {error, Reason} ->
            handle_cfg_parse_error(Reason, Path),
            {reply, last_valid, State}
    end;
handle_call(_Call, _From, State) ->
    {noreply, State}.

handle_cast(_Cast, State) ->
    {noreply, State}.

handle_info(reload, State=#state{timer=TRef}) ->
    %% This should be a no-op, unless someone sent us this message
    %% directly. In which case the cancellation is desirable to avoid
    %% accumulating more and more timers.
    _ = erlang:cancel_timer(TRef),
    {noreply, State#state{timer=undefined}, {continue, load_config}};
handle_info(_Info, State) ->
    {noreply, State}.

handle_continue(load_config, State=#state{cfg_path=Path, cfg=OldCfg}) ->
    NewState = case maestro_cfg:parse_file(Path) of
        {error, Reason} ->
            handle_cfg_parse_error(Reason, Path),
            State;
        {ok, Cfg} ->
            apply_cfg(Cfg, OldCfg),
            State#state{cfg = Cfg}
    end,
    TRef = erlang:send_after(?RELOAD_INTERVAL, self(), reload),
    {noreply, NewState#state{timer=TRef}}.


terminate(_Reason, _State) ->
    ok.

%%%%%%%%%%%%%%%
%%% PRIVATE %%%
%%%%%%%%%%%%%%%
handle_cfg_parse_error(Reason, Path) ->
    ?LOG_ERROR(#{
       log => event,
       in => maestro,
       what => config_load,
       result => error,
       details => Reason,
       file => Path
    }).

apply_cfg(Cfg, undefined) ->
    start_workers(Cfg).

start_workers(Cfg) ->
    %% start all clients first, with each client call trying to boot its own VM
    %% and assert a client mode;
    %% then start all servers, with each server call trying to boot its own VM
    %% and expecting to get a busy call in some cases when asserting the mode.
    %% This order ensures that a directory that is marked both as a client and
    %% a server (maybe because the user wants it to play both roles) is always
    %% hydrated from another server first, to avoid split leadership and id
    %% conflicts.
    start_clients(Cfg),
    start_servers(Cfg),
    ok.

start_clients(Cfg = #{<<"peers">> := PeersMap}) ->
    [start_client(Dir, Cfg, PeerName, PeerCfg)
     || {PeerName, PeerCfg = #{<<"sync">> := DirList}} <- maps:to_list(PeersMap),
        Dir <- DirList],
    ok.

start_client(DirName,
             Cfg=#{<<"db">> := #{<<"path">> := DbDir}, <<"dirs">> := DirsMap},
             PeerName, PeerCfg) ->
    #{DirName := #{<<"interval">> := Interval,
                   <<"path">> := Path}} = DirsMap,
    %% Clients can depend on multiple peers, which can all be valid;
    %% it's possible that only one of the many peers is available at
    %% first. We can try to connect to all of them, and if none is
    %% available, we can't actually get started unless an ID already
    %% existed locally.
    #{<<"auth">> := #{<<"type">> := AuthType}} = PeerCfg,
    Cb = (callback_mod(AuthType)):callback({DirName, Cfg}),
    _ = revault_fsm_sup:start_fsm(DbDir, DirName, Path, Interval, Cb),
    case revault_fsm:id(DirName) of
        undefined ->
            ok = revault_fsm:client(DirName),
            %% this call is allowed to fail if the peer isn't up at this
            %% point in time, but will keep the FSM in client mode, which
            %% we desire at this point.
            _ = revault_fsm:id(DirName, PeerName),
            ok;
        _ ->
            ok
    end.

start_servers(Cfg = #{<<"server">> := ServMap}) ->
    %% Start TLS servers first for max security, then go lower to TCP,
    %% at least until we figure out how to support many types at once.
    AuthTypesMap = maps:get(<<"auth">>, ServMap, #{}),
    TlsMap = maps:get(<<"tls">>, AuthTypesMap, #{}),
    AuthMap = maps:get(<<"authorized">>, TlsMap, #{}),
    TlsDirs = lists:usort(lists:append(
        [maps:get(<<"sync">>, AuthCfg)
         || {_Peer, AuthCfg} <- maps:to_list(AuthMap)]
    )),
    [start_server(Dir, Cfg, <<"tls">>) || Dir <- TlsDirs],
    NoneMap = maps:get(<<"none">>, AuthTypesMap, #{}),
    NoneDirs = lists:usort(maps:get(<<"sync">>, NoneMap, [])),
    [start_server(Dir, Cfg, <<"none">>) || Dir <- NoneDirs],
    ok.

start_server(DirName,
             Cfg=#{<<"db">> := #{<<"path">> := DbDir}, <<"dirs">> := DirsMap},
             Type) ->
    #{DirName := #{<<"interval">> := Interval,
                   <<"path">> := Path}} = DirsMap,
    Cb = (callback_mod(Type)):callback({DirName, Cfg}),
    _ = revault_fsm_sup:start_fsm(DbDir, DirName, Path, Interval, Cb),
    case revault_fsm:id(DirName) of
        undefined ->
            ok = revault_fsm:server(DirName);
        _ ->
            ok
    end.

%% No pattern allows disterl to work as an option here. Only works for tests.
callback_mod(<<"tls">>) -> revault_tls;
callback_mod(<<"none">>) -> revault_tcp.
