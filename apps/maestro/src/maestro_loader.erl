-module(maestro_loader).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-define(RELOAD_INTERVAL, timer:minutes(5)).

-export([start_link/0]).
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

%%%%%%%%%%%%%%%%%
%%% CALLBACKS %%%
%%%%%%%%%%%%%%%%%
init([]) ->
    CfgPath = maestro_cfg:config_path(),
    {ok, #state{cfg_path = CfgPath}, {continue, load_config}}.

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
    #{
        <<"dirs">> := DirsMap,
        <<"peers">> := PeersMap,
        <<"server">> := #{<<"auth">> := ServersAuthMap}
    } = Cfg,
    %% We assume all directories are shared in some way,
    %% either as a server or as a client. If we are the
    %% client of anything, then we need to get our initial
    %% data from another end. If we are the server of anything
    %% then we can start first.
    %% We can only start the tracker and give a hint to the
    %% type for it to start the whole hierarchy.
    %%
    %% A server that isn't shared in any way is just started
    %% as a disterl server, which shouldn't be visible to the
    %% rest of the system but could be use for local syncs
    %% and tests.
    %%
    %% At some point there's gonna be a non-disterl sync, which is
    %% what is supported here, but for the time being, just
    %% tunnel proc names and node names through; you can only
    %% invent two telephones and then improve things.
    Annotated = Cfg#{<<"dirs">> => annotate_dirs(DirsMap, ServersAuthMap, PeersMap)},
    start_workers(Annotated).

annotate_dirs(DirsMap, ServersAuthMap, PeersMap) ->
    maps:fold(fun(Dir, Map, Acc) ->
            Acc#{Dir => maps:merge(Map, annotate_dir(Dir, ServersAuthMap, PeersMap))}
        end,
        #{},
        DirsMap
    ).

start_workers(AnnotatedCfg) ->
    #{
        <<"db">> := #{<<"path">> := DbPath},
        <<"dirs">> := DirsMap
    } = AnnotatedCfg,
    [begin
         start_fsm(Dir, DbPath, Map),
         %% What do we do if a directory is both a server and a client?
         %% Should probably try to be a client first; the assumption
         %% is that it could be a mirror that first needs to fetch its ID
         %% and then can start serving data to other consumers.
         %%
         %% This implies that starting clients may block starting servers
         %% for any worker, so long as no ID is found
         %% TODO: change things such that starts are handled per-directory
         %% so that we can block per-directory rather than per client vs. server
         %% set. This would however still mess with the config reloading
         %% functionality.
         start_clients(Dir, Map),
         start_servers(Dir, Map)
     end || {Dir, Map} <- maps:to_list(DirsMap)],
    ok.

annotate_dir(Dir, ServersAuthMap, PeersMap) ->
    maps:merge_with(fun(_, M1, M2) -> maps:merge(M1, M2) end,
                    annotate_servers(Dir, ServersAuthMap),
                    annotate_peers(Dir, PeersMap)).

annotate_servers(Dir, ServersAuthMap) ->
    maps:fold(fun(Type, V=#{<<"sync">> := List}, M) ->
            case lists:member(Dir, List) of
                true ->
                    maps:update_with(<<"server">>, fun(L) -> [{Type, V}|L] end,
                                     [{Type, V}], M);
                false ->
                    M
            end
        end,
        #{},
        ServersAuthMap
    ).

annotate_peers(Dir, PeersMap) ->
    maps:fold(fun(PeerName, V=#{<<"sync">> := List}, M) ->
            case lists:member(Dir, List) of
                true ->
                    maps:update_with(<<"peers">>, fun(L) -> [{PeerName, V}|L] end,
                                     [{PeerName, V}], M);
                false ->
                    M
            end
        end,
        #{},
        PeersMap
    ).


start_fsm(Name, DbDir, #{<<"path">> := Path, <<"interval">> := Interval}) ->
    revault_fsm_sup:start_fsm(DbDir, Name, Path, Interval).

start_servers(_Name, _TypeMaps) ->
    %% If disterl type, do ensure erlang nodes are connected? The FSMs should
    %% be able to ensure that on their own though.
    ok.

start_clients(_Name, _PeerMaps) ->
    %% Clients can depend on multiple peers, which can all be valid;
    %% it's possible that only one of the many peers is available at
    %% first. We can try to connect to all of them, and if none is
    %% available, we can't actually get started unless an ID already
    %% existed locally.
    ok.
