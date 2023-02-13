%%% @doc
%%% ```
%%%                 .-------------INIT----.
%%%                 |                     |
%%%                 v                     v
%%%          UNINITIALIZED      .---->INITIALIZED-------->SERVER------.
%%%          |           |      |      |  ^                  |        |
%%%          v           v      |   .--'  |                  v        |
%%%     CLIENT_INIT    SERVER_INIT  |     |           SERVER_ID_SYNC  |
%%%          |    ^---.             |  DISCONNECT<-------'            |
%%%          v        |             |   ^                    .--------'
%%%     CONNECTING-->DISCONNECT     |   |                    |
%%%          |    .---^             |   |                    v
%%%          v    |                 |   |--------------SERVER_SYNC
%%%    CLIENT_ID_SYNC  .------------'   |                    |
%%%      |             |                |                    v
%%%      |             v                |           SERVER_SYNC_FILES
%%%      |           CLIENT-------------+--------------------'
%%%      |             | ^              |
%%%      |             v |              |
%%%      |         CONNECTING           |
%%%      |             |                |
%%%      |             v                |
%%%      |   CLIENT_SYNC_MANIFEST-------|
%%%      |             |                |
%%%      |             v                |
%%%      |     CLIENT_SYNC_FILES--------|
%%%      |             |                |
%%%      |             v                |
%%%      |   CLIENT_SYNC_COMPLETE-------|
%%%      |                              |
%%%      '------------------------------'
%%% ```
-module(revault_fsm).
-behaviour(gen_statem).
-export([start_link/4, start_link/5,
         server/1, client/1, id/1, id/2, sync/2]).
-export([%% Lifecycle
         callback_mode/0,
         init/1, %handle_event/4, terminate/3,
         %% Id initialization callbacks
         uninitialized/3, server_init/3,
         client_init/3, client_id_sync/3,
         %% initialized callbacks
         initialized/3, client/3, server/3,
         %% client-side file synchronization callbacks
         client_sync_manifest/3, client_sync_files/3, client_sync_complete/3,
         %% server-side id initialization callbacks
         server_id_sync/3,
         %% server-side file synchronization callbacks
         server_sync/3, server_sync_files/3,
         %% Connection handling
         connecting/3, disconnect/3
        ]).

-define(registry(M, N), {via, gproc, {n, l, {M, N}}}).
-define(registry(N), ?registry(?MODULE, N)).

-include_lib("opentelemetry_api/include/otel_tracer.hrl").
%% other tracing macros
-define(str(T), unicode:characters_to_binary(io_lib:format("~tp", [T]))).
-define(attrs(T), [{<<"module">>, ?MODULE},
                   {<<"function">>, ?FUNCTION_NAME},
                   {<<"line">>, ?LINE},
                   {<<"node">>, node()},
                   {<<"pid">>, ?str(self())}
                   | attrs(T)]).


-type name() :: string().

%% Substate data records, used to carry state-specific
%% information withing top-level data records
-record(connecting, {
          %% The state to transition to if the connection succeeds
          next_state :: term(),
          %% Upon success, there is an internal event
          %% being sent that contains {connect, Remote, Payload}
          next_payload = ok :: term(),
          %% The state to transition to if the connection succeeds
          fail_state :: term(),
          %% Upon failure, there is an internal event
          %% being sent that contains {connect, Remote, Payload, timeout | {error, Reason}}
          fail_payload = error :: term(),
          timeout = infinity,
          remote :: term(),
          marker = undefined :: term()
        }).

-record(disconnect, {
          %% The state to transition to if the connection succeeds
          next_state :: term(),
          next_actions = [] :: list()
        }).

-record(id_sync, {from, marker, remote}).

-record(client_sync, {from, marker, remote, acc=[]}).

-record(server, {remote}).

%% Top-level data records
-record(uninit, {
          db_dir,
          name,
          path,
          interval,
          callback,
          ctx=[],
          %% holding data used for the current substate
          sub :: undefined | #connecting{} | #disconnect{} | #id_sync{}
        }).

-record(data, {
          db_dir,
          id,
          uuid,
          name,
          path,
          interval,
          callback,
          ctx=[],
          %% holding data used for the current substate
          sub :: undefined | #connecting{} | #disconnect{}
               | #client_sync{} | #server{}
        }).

-ifdef(TEST).
-define(DEBUG_OPTS, [{debug, [trace]}]).
-else.
-define(DEBUG_OPTS, []).
-endif.

%  [dirs.images]
%  interval = 60
%  path = "/Users/ferd/images/"
%  ignore = [] # regexes on full path
start_link(DbDir, Name, Path, Interval) ->
    start_link(DbDir, Name, Path, Interval, revault_disterl).

start_link(DbDir, Name, Path, Interval, Callback) ->
    gen_statem:start_link(?registry(Name), ?MODULE, {DbDir, Name, Path, Interval, Callback}, ?DEBUG_OPTS).

-spec server(name()) -> ok | {error, busy}.
server(Name) ->
    gen_statem:call(?registry(Name), {role, server}).

-spec client(name()) -> ok | {error, busy}.
client(Name) ->
    gen_statem:call(?registry(Name), {role, client}).

-spec id(name()) -> {ok, itc:id()} | undefined | {error, _}.
id(Name) ->
    gen_statem:call(?registry(Name), id).

-spec id(name(), term()) -> {ok, itc:id()} | undefined | {error, _}.
id(Name, Remote) ->
    gen_statem:call(?registry(Name), {id, Remote}).

-spec sync(name(), term()) -> ok | {error, _}.
sync(Name, Remote) ->
    gen_statem:call(?registry(Name), {sync, Remote}).

%%%%%%%%%%%%%%%%%
%%% CALLBACKS %%%
%%%%%%%%%%%%%%%%%
callback_mode() ->
    [state_functions, state_enter].

init({DbDir, Name, Path, Interval, Callback}) ->
    process_flag(trap_exit, true),
    Id = init_id(DbDir, Name),
    UUID = init_uuid(DbDir, Name),
    case Id of
        undefined ->
            {ok, uninitialized,
             #uninit{db_dir=DbDir, name=Name, path=Path, interval=Interval,
                     callback=Callback}};
        _ ->
            {ok, initialized,
             #data{db_dir=DbDir, name=Name, path=Path, interval=Interval,
                   id = Id, uuid = UUID,
                   callback = Callback}}
    end.


uninitialized(enter, _, Data) ->
    {keep_state, Data};
uninitialized({call, From}, id, Data) ->
    {next_state, uninitialized, Data, [{reply, From, undefined}]};
uninitialized({call, From}, {role, server}, Data) ->
    %% Something external telling us we're gonna be in server mode
    {next_state, server_init, Data,
     [{reply, From, ok},
      {next_event, internal, init}]};
uninitialized({call, From}, {role, client}, Data) ->
    %% Something external telling us we're gonna be in client mode
    {next_state, client_init, Data, [{reply, From, ok}]}.

server_init(enter, uninitialized, Data) ->
    {keep_state, Data};
server_init(internal, init, #uninit{name=Name, db_dir=DbDir, path=Path,
                                    interval=Interval, callback=Cb}) ->
    Id = revault_data_wrapper:new(),
    UUID = uuid:get_v4(),
    ok = store_uuid(DbDir, Name, UUID),
    ok = store_id(DbDir, Name, Id),
    %% tracker couldn't have been booted yet
    {ok, _} = start_tracker(Name, Id, Path, Interval, DbDir),
    {next_state, server,
     #data{db_dir=DbDir, name=Name, path=Path, interval=Interval, callback=Cb,
           id=Id, uuid=UUID}};
server_init(_, _, Data) ->
    {keep_state, Data, [postpone]}.

client_init(enter, _, Data=#uninit{}) ->
    {keep_state, Data};
client_init({call, From}, {role, _}, Data) ->
    {keep_state, Data, [{reply, From, {error, busy}}]};
client_init({call, From}, id, Data=#uninit{}) ->
    {keep_state, Data, [{reply, From, undefined}]};
client_init({call, From}, {id, Remote}, Data=#uninit{callback=Cb}) ->
    {_, NewCb} = apply_cb(Cb, mode, [client]),
    %% The connecting substate is using a sort of data-based callback mechanism
    %% where we ask of it to run a connection, and then describe to it
    %% how to transition in case of failure or success.
    {next_state, connecting,
     Data#uninit{sub=#connecting{
        next_state=client_id_sync,
        next_payload={call,From},
        fail_state=client_init,
        fail_payload={call,From}
     }, callback= NewCb},
     [{next_event, internal, {connect, Remote}}]};
client_init(internal, {connect, _, {call, From}, _Reason}, Data) ->
    %% From the connecting state
    %% TODO: log the internal error
    {keep_state, Data, [{reply, From, {error, sync_failed}}]};
client_init(_, _, Data) ->
    {keep_state, Data, [postpone]}.

connecting(enter, _OldState, Data) ->
    {keep_state, Data};
connecting(internal, {connect, Remote},
           DataTmp=#data{name=Name, callback=Cb, sub=Conn, uuid=UUID}) ->
    Data = start_span(<<"connect">>, DataTmp),
    set_attributes([{<<"peer">>, ?str(Remote)} | ?attrs(Data)]),
    {Res, NewCb} = apply_cb(Cb, peer, [Name, Remote, #{uuid=>UUID,
                                                       ctx=>get_span(DataTmp)}]),
    case Res of
        {ok, Marker} ->
            %% Await confirmation from the peer
            {next_state, connecting,
             Data#data{callback=NewCb,
                       sub=Conn#connecting{marker=Marker, remote=Remote}},
             [{state_timeout, Conn#connecting.timeout, {connect, Remote}}]};
        {error, Reason} ->
            %% Bail out
            ?add_event(<<"connection_failed">>, [{<<"error">>, Reason}]),
            NewData = end_span(Data),
            otel_ctx:clear(),
            #connecting{fail_state=State, fail_payload=Payload} = Conn,
            {next_state, State,
             NewData#data{callback=NewCb, sub=undefined},
             [{next_event, internal, {connect, Remote, Payload, {error, Reason}}}]}
    end;
connecting(info, {revault, Marker, ok},
           Data=#data{sub=S=#connecting{marker=Marker}}) ->
    %% Transition to a successful state
    ?add_event(<<"connection_successful">>, []),
    NewData = end_span(Data),
    #connecting{next_state=State, next_payload=Payload, remote=Remote} = S,
    {next_state, State,
     NewData#data{sub=undefined},
     [{next_event, internal, {connect, Remote, Payload}}]};
connecting(info, {revault, Marker, Err},
           Data=#data{sub=S=#connecting{marker=Marker}}) ->
    ?add_event(<<"connection_failed">>, [{<<"error">>, Err}]),
    NewData = end_span(Data),
    otel_ctx:clear(),
    #connecting{fail_state=State, fail_payload=Payload, remote=Remote} = S,
    Disconnect = #disconnect{
        next_state=State,
        next_actions=[{next_event, internal, {connect, Remote, Payload, Err}}]
    },
    {next_state, disconnect, NewData#data{sub=Disconnect},
     [{next_event, internal, {disconnect, Remote}}]};
connecting(state_timeout, {connect, Remote}, Data=#data{sub=S}) ->
    %% We took too long, bail out, but first send an explicit unpeer call
    %% in case we had a race condition. We may end up with a FSM that receives
    %% a late {revault, Marker, ok} message out of this.
    ?add_event(<<"connection_timeout">>, []),
    NewData = end_span(Data),
    otel_ctx:clear(),
    #connecting{fail_state=State, fail_payload=Payload} = S,
    Disconnect = #disconnect{
        next_state=State,
        next_actions=[{next_event, internal, {connect, Remote, Payload, timeout}}]
    },
    {next_state, disconnect, NewData#data{sub=Disconnect},
     [{next_event, internal, {disconnect, Remote}}]};
%% And now we unfortunately repeat the whole ordeal with the #uninit{} state record...
%% There is one difference though, the uninitialized version does not pass a UUID for
%% safety since until initialization, the client has none.
connecting(internal, {connect, Remote}, DataTmp=#uninit{name=Name, callback=Cb, sub=Conn}) ->
    Data = start_span(<<"connect">>, DataTmp),
    set_attributes([{<<"peer">>, ?str(Remote)} | ?attrs(Data)]),
    {Res, NewCb} = apply_cb(Cb, peer, [Name, Remote, #{}]),
    case Res of
        {ok, Marker} ->
            %% Await confirmation from the peer
            {next_state, connecting,
             Data#uninit{callback=NewCb,
                       sub=Conn#connecting{marker=Marker, remote=Remote}},
             [{state_timeout, Conn#connecting.timeout, {connect, Remote}}]};
        {error, Reason} ->
            %% Bail out
            ?add_event(<<"connection_failed">>, [{<<"error">>, Reason}]),
            NewData = end_span(Data),
            otel_ctx:clear(),
            #connecting{fail_state=State, fail_payload=Payload} = Conn,
            {next_state, State,
             NewData#uninit{callback=NewCb, sub=undefined},
             [{next_event, internal, {connect, Remote, Payload, {error, Reason}}}]}
    end;
connecting(info, {revault, Marker, ok},
           Data=#uninit{sub=S=#connecting{marker=Marker}}) ->
    %% Transition to a successful state
    ?add_event(<<"connection_successful">>, []),
    NewData = end_span(Data),
    #connecting{next_state=State, next_payload=Payload, remote=Remote} = S,
    {next_state, State,
     NewData#uninit{sub=undefined},
     [{next_event, internal, {connect, Remote, Payload}}]};
connecting(info, {revault, Marker, Err},
           Data=#uninit{sub=S=#connecting{marker=Marker}}) ->
    ?add_event(<<"connection_failed">>, [{<<"error">>, Err}]),
    NewData = end_span(Data),
    otel_ctx:clear(),
    #connecting{fail_state=State, fail_payload=Payload, remote=Remote} = S,
    Disconnect = #disconnect{
        next_state=State,
        next_actions=[{next_event, internal, {connect, Remote, Payload, Err}}]
    },
    {next_state, disconnect, NewData#uninit{sub=Disconnect},
     [{next_event, internal, {disconnect, Remote}}]};
connecting(state_timeout, {connect, Remote}, Data=#uninit{sub=S}) ->
    %% We took too long, bail out, but first disconnect
    %% in case we had a race condition. We may end up with a FSM that receives
    %% a late {revault, Marker, ok} message out of this.
    ?add_event(<<"connection_timeout">>, []),
    NewData = end_span(Data),
    otel_ctx:clear(),
    #connecting{fail_state=State, fail_payload=Payload} = S,
    Disconnect = #disconnect{
        next_state=State,
        next_actions=[{next_event, internal, {connect, Remote, Payload, timeout}}]
    },
    {next_state, disconnect, NewData#uninit{sub=Disconnect},
     [{next_event, internal, {disconnect, Remote}}]};
connecting(_, _, Data) ->
    {keep_state, Data, [postpone]}.

disconnect(enter, _, Data) ->
    {keep_state, Data};
disconnect(internal, {disconnect, Remote}, Data=#data{name=Name, callback=Cb, sub=S}) ->
    {_, NewCb} = apply_cb(Cb, unpeer, [Name, Remote]),
    #disconnect{next_state=State, next_actions=Actions} = S,
    {next_state, State, Data#data{sub=undefined, callback=NewCb}, Actions};
disconnect(internal, {disconnect, Remote}, Data=#uninit{name=Name, callback=Cb, sub=S}) ->
    {_, NewCb} = apply_cb(Cb, unpeer, [Name, Remote]),
    #disconnect{next_state=State, next_actions=Actions} = S,
    {next_state, State, Data#uninit{sub=undefined, callback=NewCb}, Actions};
disconnect(_, _, Data) ->
    {keep_state, Data, [postpone]}.

client_id_sync(enter, connecting, Data=#uninit{}) ->
    {keep_state, Data};
client_id_sync(internal, {connect, Remote, {call,From}}, Data=#uninit{callback=Cb}) ->
    {Res, NewCb} = apply_cb(Cb, send, [Remote, revault_data_wrapper:ask()]),
    case Res of
        {ok, Marker} ->
            {keep_state,
             Data#uninit{callback=NewCb,
                         sub=#id_sync{from=From, remote=Remote, marker=Marker}}};
        {error, _R} ->
            %% TODO: log internal error
            Disconnect = #disconnect{next_state=client_init},
            {next_state, disconnect, Data#uninit{sub=Disconnect},
             [{reply, From, {error, sync_failed}},
              {next_event, internal, {disconnect, Remote}}]}
    end;
client_id_sync(info, {revault, Marker, {error, _R}},
               Data=#uninit{sub=#id_sync{from=From, marker=Marker, remote=Remote}}) ->
    %% TODO: log internal error
    Disconnect = #disconnect{next_state=client_init},
    {next_state, disconnect, Data#uninit{sub=Disconnect},
     [{reply, From, {error, sync_failed}},
      {next_event, internal, {disconnect, Remote}}]};
client_id_sync(info, {revault, Marker, {reply, {NewId,UUID}}},
               Data=#uninit{sub=#id_sync{from=From, marker=Marker, remote=Remote}}) ->
    #uninit{db_dir=Dir, name=Name, path=Path, interval=Interval,
            callback=Cb} = Data,
    ok = store_uuid(Dir, Name, UUID),
    ok = store_id(Dir, Name, NewId),
    %% tracker couldn't have been booted yet
    {ok, _} = start_tracker(Name, NewId, Path, Interval, Dir),
    %% Disconnect before moving on
    Disconnect = #disconnect{next_state = initialized},
    {next_state, disconnect,
     #data{db_dir=Dir, id=NewId, uuid=UUID, name=Name, path=Path,
           interval=Interval, callback=Cb, sub=Disconnect},
     [{reply, From, {ok, NewId}},
      {next_event, internal, {disconnect, Remote}}]};
client_id_sync(_, _, Data) ->
    {keep_state, Data, [postpone]}.

initialized(enter, _, Data=#data{name=Name, id=Id, path=Path, interval=Interval, db_dir=DbDir}) ->
    ?end_span(), % if any
    _ = start_tracker(Name, Id, Path, Interval, DbDir),
    {keep_state, Data};
initialized({call, From}, id, Data=#data{id=Id}) ->
    {keep_state, Data, [{reply, From, {ok, Id}}]};
initialized({call, From}, {role, client}, Data) ->
    {next_state, client, Data, [{reply, From, ok}]};
initialized({call, From}, {role, server}, Data) ->
    {next_state, server, Data, [{reply, From, ok}]};
initialized({call, _From}, {id, _Remote}, Data) ->
    %% consider this to be an implicit {role, client} call
    {next_state, client, Data, [postpone]};
initialized({call, _From}, {sync, _Remote}, Data) ->
    %% consider this to be an implicit {role, client} call
    {next_state, client, Data, [postpone]};
initialized(info, {revault, _Marker, {peer, _Remote, _Attrs}}, Data) ->
    %% consider this to be an implicit {role, server} shift;
    %% TODO: add a "wait_role" sort of call if this ends up
    %% preventing client calls from happening on a busy server?
    {next_state, server, Data, [postpone]}.

client(enter, _, Data = #data{callback=Cb}) ->
    {_, NewCb} = apply_cb(Cb, mode, [client]),
    {keep_state, Data#data{callback=NewCb}};
client({call, From}, id, Data=#data{id=Id}) ->
    {keep_state, Data, [{reply, From, {ok, Id}}]};
client({call, From}, {id, _}, Data=#data{id=Id}) ->
    %% Ignore the call for a remote and just send the ID we already know
    {keep_state, Data, [{reply, From, {ok, Id}}]};
client({call, From}, {sync, Remote}, DataTmp) ->
    Data = start_span(<<"sync">>, DataTmp),
    set_attributes([{<<"peer">>, ?str(Remote)} | ?attrs(Data)]),
    {next_state, connecting,
     Data#data{sub=#connecting{
        next_state=client_sync_manifest,
        next_payload={call,From},
        fail_state=client,
        fail_payload={call,From}
     }},
     [{next_event, internal, {connect, Remote}}]};
client(internal, {connect, _, {call, From}, Reason}, Data) ->
    %% From the connecting state, go back to initialized
    {next_state, initialized, Data, [{reply, From, Reason}]}.

client_sync_manifest(enter, _, Data) ->
    {keep_state, Data};
client_sync_manifest(internal, {connect, Remote, {call,From}}, DataTmp=#data{callback=Cb}) ->
    Data = start_span(<<"ask_manifest">>, DataTmp),
    set_attributes([{<<"peer">>, ?str(Remote)} | ?attrs(Data)]),
    {Res, NewCb} = apply_cb(Cb, send, [Remote, revault_data_wrapper:manifest()]),
    case Res of
        {ok, Marker} ->
            {keep_state,
             Data#data{callback=NewCb,
                       sub=#client_sync{from=From, remote=Remote,
                                        marker=Marker}}};
        {error, R} ->
            Disconnect = #disconnect{next_state=initialized},
            {next_state, disconnect, Data#data{sub=Disconnect},
             [{reply, From, {error, R}},
              {next_event, internal, {disconnect, Remote}}]}
    end;
client_sync_manifest(info, {revault, Marker, {manifest, RManifest}},
                     DataTmp=#data{sub=#client_sync{marker=Marker},
                                   name=Name, id=Id}) ->
    Data = start_span(<<"diff_manifest">>, end_span(DataTmp)),
    LManifest = revault_dirmon_tracker:files(Name),
    {Local, Remote} = diff_manifests(Id, LManifest, RManifest),
    Actions = schedule_file_transfers(Local, Remote),
    set_attributes([{<<"to_send">>, length(Local)},
                    {<<"to_recv">>, length(Remote)} | ?attrs(Data)]),
    NewData = end_span(Data),
    {next_state, client_sync_files, NewData,
     Actions ++ [{next_event, internal, sync_complete}]};
client_sync_manifest(_, _, Data) ->
    {keep_state, Data, [postpone]}.

client_sync_files(enter, _, Data) ->
    {keep_state, Data};
client_sync_files(internal, {send, File},
                  DataTmp=#data{name=Name, path=Path, callback=Cb,
                                sub=#client_sync{remote=R}}) ->
    Data = start_span(<<"file_send">>, DataTmp),
    set_attributes([{<<"peer">>, ?str(R)}, {<<"path">>, File} | ?attrs(Data)]),
    Payload = case revault_dirmon_tracker:file(Name, File) of
        {Vsn, deleted} ->
            revault_data_wrapper:send_deleted(File, Vsn);
        {Vsn, Hash} ->
            %% TODO: optimize to read and send files in parts rather than
            %% just reading it all at once and loading everything in memory
            %% and shipping it in one block
            {ok, Bin} = file:read_file(filename:join(Path, File)),
            revault_data_wrapper:send_file(File, Vsn, Hash, Bin)
    end,
    %% TODO: track the success or failures of transfers, detect disconnections
    {_Marker, NewCb} = apply_cb(Cb, send, [R, Payload]),
    NewData = end_span(DataTmp),
    {keep_state, NewData#data{callback=NewCb}};
client_sync_files(internal, {fetch, File},
                  Data=#data{callback=Cb, sub=S=#client_sync{remote=R, acc=Acc}}) ->
    ?with_span(<<"file_fetch">>,
        #{attributes => [{<<"path">>, File}, {<<"peer">>, ?str(R)} | ?attrs(Data)]},
        fun(_SpanCtx) ->
            Payload = revault_data_wrapper:fetch_file(File),
            %% TODO: track the incoming transfers to know when we're done syncing
            {_Marker, NewCb} = apply_cb(Cb, send, [R, Payload]),
            {keep_state, Data#data{callback=NewCb, sub=S#client_sync{acc=[File|Acc]}}}
        end);
client_sync_files(internal, sync_complete, Data=#data{sub=#client_sync{acc=[]}}) ->
    #data{callback=Cb, sub=#client_sync{remote=R}} = Data,
    Payload = revault_data_wrapper:sync_complete(),
    %% TODO: handle failure here
    {_Marker, NewCb} = apply_cb(Cb, send, [R, Payload]),
    {next_state, client_sync_complete, Data#data{callback=NewCb}};
client_sync_files(internal, sync_complete, Data) ->
    %% wait for all files we're fetching to be here, and when the last one is in,
    %% re-trigger a sync_complete message
    {keep_state, Data};
client_sync_files(info, {revault, _Marker, {file, F, Meta, Bin}}, Data) ->
    #data{name=Name, id=Id, sub=S=#client_sync{acc=Acc}} = Data,
    ?with_span(<<"file_recv">>,
        #{attributes => [{<<"path">>, F}, {<<"size">>, byte_size(Bin)},
                         {<<"meta">>, ?str(Meta)} | ?attrs(Data)]},
        fun(_SpanCtx) ->
            handle_file_sync(Name, Id, F, Meta, Bin)
        end),
    case Acc -- [F] of
        [] ->
            {keep_state, Data#data{sub=S#client_sync{acc=[]}},
             [{next_event, internal, sync_complete}]};
        NewAcc ->
            {keep_state, Data#data{sub=S#client_sync{acc=NewAcc}}}
    end;
client_sync_files(info, {revault, _Marker, {deleted_file, F, Meta}}, Data) ->
    #data{name=Name, id=Id, sub=S=#client_sync{acc=Acc}} = Data,
    ?with_span(<<"deleted">>, #{attributes => [{<<"path">>, F}, {<<"meta">>, ?str(Meta)}
                                               | ?attrs(Data)]},
               fun(_SpanCtx) -> handle_delete_sync(Name, Id, F, Meta) end),
    case Acc -- [F] of
        [] ->
            {keep_state, Data#data{sub=S#client_sync{acc=[]}},
             [{next_event, internal, sync_complete}]};
        NewAcc ->
            {keep_state, Data#data{sub=S#client_sync{acc=NewAcc}}}
    end;
client_sync_files(info, {revault, _Marker, {conflict_file, WorkF, F, CountLeft, Meta, Bin}}, Data) ->
    #data{name=Name, sub=S=#client_sync{acc=Acc}} = Data,
    ?with_span(
       <<"conflict">>,
       #{attributes => [{<<"path">>, F}, {<<"meta">>, ?str(Meta)},
                        {<<"count">>, CountLeft} | ?attrs(Data)]},
       fun(_SpanCtx) ->
           %% TODO: handle the file being corrupted vs its own hash
           TmpF = revault_file:tmp(F),
           filelib:ensure_dir(TmpF),
           ok = file:write_file(TmpF, Bin),
           revault_dirmon_tracker:conflict(Name, WorkF, TmpF, Meta),
           file:delete(TmpF)
        end
    ),
    case CountLeft =:= 0 andalso Acc -- [WorkF] of
        false ->
            %% more of the same conflict file to come
            {keep_state, Data};
        [] ->
            {keep_state, Data#data{sub=S#client_sync{acc=[]}},
             [{next_event, internal, sync_complete}]};
        NewAcc ->
            {keep_state, Data#data{sub=S#client_sync{acc=NewAcc}}}
    end;
client_sync_files(_, _, Data) ->
    {keep_state, Data, [postpone]}.

client_sync_complete(enter, _, Data=#data{name=Name}) ->
    %% force scan to ensure conflict files (if any) are tracked before
    %% users start modifying them. Might not be relevant when things like
    %% filesystem watchers are used, but I'm starting to like the idea of
    %% on-demand scan/sync only.
    ?with_span(<<"force_scan">>, #{attributes => ?attrs(Data)},
        fun(_SpanCtx) ->
            ok = revault_dirmon_event:force_scan(Name, infinity)
        end),
    {keep_state, Data};
client_sync_complete(info, {revault, _Marker, sync_complete},
                     DataTmp=#data{sub=#client_sync{from=From, remote=Remote}}) ->
    Disconnect = #disconnect{next_state=initialized},
    Data = end_span(DataTmp),
    otel_ctx:clear(),
    {next_state, disconnect, Data#data{sub=Disconnect},
     [{reply, From, ok},
      {next_event, internal, {disconnect, Remote}}]};
client_sync_complete(_, _, Data) ->
    {keep_state, Data, [postpone]}.

server(enter, _, Data = #data{callback=Cb}) ->
    {_Res, NewCb} = apply_cb(Cb, mode, [server]),
    {keep_state, Data#data{callback=NewCb}};
server({call, From}, {role, _}, Data) ->
    %% TODO: support switching to client role is not connected.
    {keep_state, Data, [{reply, From, {error, busy}}]};
server({call, From}, id, Data=#data{id=Id}) ->
    {keep_state, Data, [{reply, From, {ok, Id}}]};
server(info, {revault, Marker, {peer, Remote, Attrs=#{uuid:=UUID}}},
       DataTmp=#data{sub=undefined, uuid=UUID, callback=Cb}) ->
    %% TODO: handle error
    Data = start_span(<<"accept_peer">>, maybe_add_ctx(Attrs, DataTmp)),
    set_attributes([{<<"remote">>, ?str(Remote)}, {<<"status">>, ok} | ?attrs(Data)]),
    {_, Cb2} = apply_cb(Cb, accept_peer, [Remote, Marker]),
    {_, NewCb} = apply_cb(Cb2, reply, [Remote, Marker, revault_data_wrapper:ok()]),
    NewData = end_span(Data),
    {keep_state, NewData#data{callback=NewCb, sub=#server{remote=Remote}}};
server(info, {revault, Marker, {peer, Remote, #{uuid:=BadUUID}}}, DataTmp=#data{sub=undefined, callback=Cb}) ->
    Data = start_span(<<"accept_peer">>, DataTmp),
    set_attributes([{<<"remote">>, ?str(Remote)}, {<<"status">>, bad_uuid},
                     {<<"peer_uuid">>, BadUUID} | ?attrs(Data)]),
    Payload = revault_data_wrapper:error({invalid_peer, BadUUID}),
    {_, NewCb} = apply_cb(Cb, reply, [Remote, Marker, Payload]),
    NewData = end_span(Data),
    {keep_state, NewData#data{callback=NewCb}};
server(info, {revault, Marker, {peer, Remote, _Attrs}}, DataTmp=#data{sub=undefined, callback=Cb}) ->
    %% TODO: handle error
    Data = start_span(<<"accept_peer">>, DataTmp),
    set_attributes([{<<"remote">>, ?str(Remote)}, {<<"status">>, ok} | ?attrs(Data)]),
    {_, Cb2} = apply_cb(Cb, accept_peer, [Remote, Marker]),
    {_, NewCb} = apply_cb(Cb2, reply, [Remote, Marker, revault_data_wrapper:ok()]),
    NewData = end_span(Data),
    {keep_state, NewData#data{callback=NewCb, sub=#server{remote=Remote}}};
server(info, {revault, Marker, {peer, Remote, _}}, DataTmp=#data{callback=Cb}) ->
    %% TODO: consider postponing the message to respond later?
    Data = start_span(<<"accept_peer">>, DataTmp),
    set_attributes([{<<"remote">>, ?str(Remote)}, {<<"status">>, busy} | ?attrs(Data)]),
    Payload = revault_data_wrapper:error(peer_busy),
    {_, NewCb} = apply_cb(Cb, reply, [Remote, Marker, Payload]),
    NewData = end_span(Data),
    {keep_state, NewData#data{callback=NewCb}};
server(info, {revault, _Marker, ask}, Data=#data{sub=#server{}}) ->
    {next_state, server_id_sync, Data, [postpone]};
server(info, {revault, _Marker, manifest}, Data=#data{sub=#server{}}) ->
    {next_state, server_sync, Data, [postpone]}.

server_id_sync(enter, _, Data) ->
    {keep_state, Data};
server_id_sync(info, {revault, Marker, ask},
       Data=#data{name=Name, id=Id, uuid=UUID, callback=Cb,
                  db_dir=Dir, sub=#server{remote=R}}) ->
    {NewId, Payload} = revault_data_wrapper:fork(Id, UUID),
    %% Save NewId to disk before replying to avoid issues
    ok = store_id(Dir, Name, NewId),
    %% Inject the new ID into all the local handlers before replying
    %% to avoid concurrency issues
    ok = revault_dirmon_tracker:update_id(Name, NewId),
    {_, Cb1} = apply_cb(Cb, reply, [R, Marker, Payload]),
    Disconnect = #disconnect{next_state=initialized},
    {next_state, disconnect, Data#data{id=NewId, callback=Cb1, sub=Disconnect},
     [{next_event, internal, {disconnect, R}}]}.

server_sync(enter, _, Data=#data{}) ->
    {keep_state, Data};
server_sync(info, {revault, Marker, manifest},
       DataTmp=#data{name=Name, callback=Cb, sub=#server{remote=R}}) ->
    Data = start_span(<<"server_sync">>, DataTmp),
    set_attributes(?attrs(Data)),
    ?with_span(<<"sent_manifest">>, #{attributes => ?attrs(Data)},
        fun(_SpanCtx) ->
            Manifest = revault_dirmon_tracker:files(Name),
            Payload = revault_data_wrapper:manifest(Manifest),
            {_, Cb1} = apply_cb(Cb, reply, [R, Marker, Payload]),
            {next_state, server_sync_files, Data#data{callback=Cb1}}
        end).


server_sync_files(enter, _, Data) ->
    {keep_state, Data};
server_sync_files(info, {revault, _Marker, {file, F, Meta, Bin}},
                  Data=#data{name=Name, id=Id}) ->
    ?with_span(<<"file_recv">>,
        #{attributes => [{<<"path">>, F}, {<<"size">>, byte_size(Bin)},
                         {<<"meta">>, ?str(Meta)} | ?attrs(Data)]},
        fun(_SpanCtx) ->
            handle_file_sync(Name, Id, F, Meta, Bin)
        end),
    {keep_state, Data};
server_sync_files(info, {revault, _Marker, {deleted_file, F, Meta}},
                  Data=#data{name=Name, id=Id}) ->
    ?with_span(<<"deleted">>, #{attributes => [{<<"path">>, F}, {<<"meta">>, ?str(Meta)}
                                               | ?attrs(Data)]},
               fun(_SpanCtx) -> handle_delete_sync(Name, Id, F, Meta) end),
    {keep_state, Data};
server_sync_files(info, {revault, _M, {conflict_file, WorkF, F, CountLeft, Meta, Bin}}, Data) ->
    %% TODO: handle the file being corrupted vs its own hash
    ?with_span(
       <<"conflict">>,
       #{attributes => [{<<"path">>, F}, {<<"meta">>, ?str(Meta)},
                        {<<"count">>, CountLeft} | ?attrs(Data)]},
       fun(_SpanCtx) ->
           TmpF = revault_file:tmp(F),
           filelib:ensure_dir(TmpF),
           ok = file:write_file(TmpF, Bin),
           revault_dirmon_tracker:conflict(Data#data.name, WorkF, TmpF, Meta),
           file:delete(TmpF)
       end
    ),
    {keep_state, Data};
server_sync_files(info, {revault, Marker, {fetch, F}}, Data) ->
    NewData = handle_file_demand(F, Marker, Data),
    {keep_state, NewData};
server_sync_files(info, {revault, Marker, sync_complete},
                  DataTmp=#data{name=Name, callback=Cb,
                                sub=#server{remote=R}}) ->
    %% force scan to ensure conflict files (if any) are tracked before
    %% users start modifying them. Might not be relevant when things like
    %% filesystem watchers are used, but I'm starting to like the idea of
    %% on-demand scan/sync only.
    ?with_span(<<"force_scan">>, #{attributes => ?attrs(DataTmp)},
        fun(_SpanCtx) ->
            ok = revault_dirmon_event:force_scan(Name, infinity)
        end),
    NewPayload = revault_data_wrapper:sync_complete(),
    {_, Cb1} = apply_cb(Cb, reply, [R, Marker, NewPayload]),
    Data = end_span(DataTmp),
    otel_ctx:clear(),
    Disconnect = #disconnect{next_state=initialized},
    {next_state, disconnect, Data#data{callback=Cb1, sub=Disconnect},
     [{next_event, internal, {disconnect, R}}]};
server_sync_files(info, {revault, Marker, {peer, Peer, _Attrs}},
                  Data=#data{callback=Cb}) ->
    Payload = revault_data_wrapper:error(peer_busy),
    {_, Cb2} = apply_cb(Cb, reply, [Peer, Marker, Payload]),
    {keep_state, Data#data{callback=Cb2}}.


%%%%%%%%%%%%%%%
%%% PRIVATE %%%
%%%%%%%%%%%%%%%
apply_cb({Mod, State}, F, Args) when is_atom(Mod) ->
    apply(Mod, F, Args ++ [State]);
apply_cb(Mod, F, Args) when is_atom(Mod) ->
    {apply(Mod, F, Args), Mod}.

init_id(Dir, Name) ->
    Path = filename:join([Dir, Name, "id"]),
    case file:read_file(Path) of
        {error, enoent} -> undefined;
        {ok, Bin} -> binary_to_term(Bin)
    end.

init_uuid(Dir, Name) ->
    Path = filename:join([Dir, Name, "uuid"]),
    case file:read_file(Path) of
        {error, enoent} -> undefined;
        {ok, Bin} -> binary_to_term(Bin)
    end.

%% Callback-mode, Dir is the carried state.
store_id(Dir, Name, Id) ->
    Path = filename:join([Dir, Name, "id"]),
    PathTmp = filename:join([Dir, Name, "id.tmp"]),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(PathTmp, term_to_binary(Id)),
    ok = file:rename(PathTmp, Path).

store_uuid(Dir, Name, UUID) ->
    Path = filename:join([Dir, Name, "uuid"]),
    PathTmp = filename:join([Dir, Name, "uuid.tmp"]),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(PathTmp, term_to_binary(UUID)),
    ok = file:rename(PathTmp, Path).

start_tracker(Name, Id, Path, Interval, DbDir) ->
    revault_trackers_sup:start_tracker(Name, Id, Path, Interval, DbDir).

diff_manifests(Id, LocalMap, RemoteMap) when is_map(LocalMap), is_map(RemoteMap) ->
    diff_manifests(Id,
                   lists:sort(maps:to_list(LocalMap)),
                   lists:sort(maps:to_list(RemoteMap)),
                   [], []).

diff_manifests(Id, [H|Loc], [H|Rem], LAcc, RAcc) ->
    diff_manifests(Id, Loc, Rem, LAcc, RAcc);
diff_manifests(Id, [{F, {LVsn, _}}|Loc], [{F, {RVsn, _}}|Rem], LAcc, RAcc) ->
    case compare(Id, LVsn, RVsn) of
        equal ->
            %% We can skip this, even though bumping versions could be nice since
            %% they differ but compare equal
            diff_manifests(Id, Loc, Rem, LAcc, RAcc);
        conflict ->
            %% Conflict! Fetch & Push in both cases
            diff_manifests(Id, Loc, Rem,
                           [{send, F}|LAcc],
                           [{fetch, F}|RAcc]);
        greater ->
            %% Local's newer
            diff_manifests(Id, Loc, Rem, [{send, F}|LAcc], RAcc);
        lesser ->
            %% Remote's newer
            diff_manifests(Id, Loc, Rem, LAcc, [{fetch, F}|RAcc])
    end;
diff_manifests(Id, [{LF, _}=L|Loc], [{RF, _}=R|Rem], LAcc, RAcc) ->
    if LF < RF ->
           diff_manifests(Id, Loc, [R|Rem], [{send, LF}|LAcc], RAcc);
       LF > RF ->
           diff_manifests(Id, [L|Loc], Rem, LAcc, [{fetch, RF}|RAcc])
    end;
diff_manifests(_Id, Loc, [], LAcc, RAcc) ->
    {[{send, F} || {F, _} <- Loc] ++ LAcc, RAcc};
diff_manifests(_Id, [], Rem, LAcc, RAcc) ->
    {LAcc, [{fetch, F} || {F, _} <- Rem] ++ RAcc}.

schedule_file_transfers(Local, Remote) ->
    %% TODO: Do something smart at some point. Right now, who cares.
    [{next_event, internal, Event} || Event <- Remote ++ Local].

compare(Id, Ct1, Ct2) ->
    ITC1 = itc:rebuild(Id, Ct1),
    ITC2 = itc:rebuild(Id, Ct2),
    case {itc:leq(ITC1, ITC2), itc:leq(ITC2, ITC1)} of
        {false, false} -> conflict;
        {true, true} -> equal;
        {true, false} -> lesser;
        {false, true} -> greater
    end.

handle_delete_sync(Name, Id, F, Meta = {Vsn, deleted}) ->
    %% is this file a conflict or an update?
    case revault_dirmon_tracker:file(Name, F) of
        undefined ->
            delete_file(Name, F, Meta);
        {LVsn, _HashOrStatus} ->
            case compare(Id, LVsn, Vsn) of
                conflict ->
                    revault_dirmon_tracker:conflict(Name, F, Meta);
                _ ->
                    delete_file(Name, F, Meta)
            end
    end.

handle_file_sync(Name, Id, F, Meta = {_Vsn, Hash}, Bin) ->
    case validate_hash(Hash, Bin) of
        false ->
            %% TODO: add some logging when the hash doesn't match
            skip;
        true ->
            do_handle_file_sync(Name, Id, F, Meta, Bin)
    end.

do_handle_file_sync(Name, Id, F, Meta = {Vsn, Hash}, Bin) ->
    %% is this file a conflict or an update?
    case revault_dirmon_tracker:file(Name, F) of
        undefined ->
            update_file(Name, F, Meta, Bin);
        {LVsn, _HashOrStatus} ->
            case compare(Id, LVsn, Vsn) of
                conflict ->
                    FHash = revault_conflict_file:conflicting(F, Hash),
                    TmpF = revault_file:tmp(FHash),
                    file:write_file(TmpF, Bin),
                    revault_dirmon_tracker:conflict(Name, F, TmpF, Meta),
                    file:delete(TmpF);
                _ ->
                    update_file(Name, F, Meta, Bin)
            end
    end.

delete_file(Name, F, Meta) ->
    case file:delete(F) of
        ok -> ok;
        {error, enoent} -> ok
    end,
    revault_dirmon_tracker:delete_file(Name, F, Meta).

update_file(Name, F, Meta, Bin) ->
    TmpF = revault_file:tmp(F),
    filelib:ensure_dir(TmpF),
    ok = file:write_file(TmpF, Bin),
    revault_dirmon_tracker:update_file(Name, F, TmpF, Meta),
    file:delete(TmpF).

validate_hash({conflict, Hashes, _}, Bin) ->
    Hash = revault_dirmon_poll:hash(Bin),
    lists:member(Hash, Hashes);
validate_hash(Hash, Bin) ->
    Hash =:= revault_dirmon_poll:hash(Bin).

handle_file_demand(F, Marker, DataTmp=#data{name=Name, path=Path, callback=Cb1,
                                            sub=#server{remote=R}}) ->
    Data = start_span(<<"file_demand">>, DataTmp),
    set_attributes([{<<"peer">>, ?str(R)}, {<<"path">>, F} | ?attrs(Data)]),
    case revault_dirmon_tracker:file(Name, F) of
        {Vsn, {conflict, Hashes, _}} ->
            %% Stream all the files, mark as conflicts?
            %% just inefficiently read the whole freaking thing at once
            %% TODO: optimize to better read and send file parts
            {Cb2, _} = lists:foldl(
                fun(Hash, {CbAcc1, Ct}) ->
                    FHash = revault_conflict_file:conflicting(F, Hash),
                    {ok, Bin} = file:read_file(filename:join(Path, FHash)),
                    NewPayload = revault_data_wrapper:send_conflict_file(F, FHash, Ct, {Vsn, Hash}, Bin),
                    %% TODO: track failing or succeeding transfers?
                    {ok, CbAcc2} = apply_cb(CbAcc1, reply, [R, Marker, NewPayload]),
                    {CbAcc2, Ct-1}
                end,
                {Cb1, length(Hashes)-1},
                Hashes
            ),
            set_attribute(<<"conflict">>, length(Hashes)),
            NewData = end_span(Data),
            NewData#data{callback=Cb2};
        {Vsn, deleted} ->
            NewPayload = revault_data_wrapper:send_deleted(F, Vsn),
            %% TODO: track failing or succeeding transfers?
            {ok, Cb2} = apply_cb(Cb1, reply, [R, Marker, NewPayload]),
            NewData = end_span(Data),
            NewData#data{callback=Cb2};
        {Vsn, Hash} ->
            %% just inefficiently read the whole freaking thing at once
            %% TODO: optimize to better read and send file parts
            {ok, Bin} = file:read_file(filename:join(Path, F)),
            NewPayload = revault_data_wrapper:send_file(F, Vsn, Hash, Bin),
            %% TODO: track failing or succeeding transfers?
            {ok, Cb2} = apply_cb(Cb1, reply, [R, Marker, NewPayload]),
            NewData = end_span(Data),
            NewData#data{callback=Cb2}
    end.

attrs(#data{name=Dir, uuid=DirUUID}) ->
    [{<<"dir">>, Dir}, {<<"dir_uuid">>, DirUUID}];
attrs(#uninit{name=Dir}) ->
    [{<<"dir">>, Dir}].

maybe_add_ctx(#{ctx:=SpanCtx}, Data=#data{ctx=Stack}) ->
    Ctx = otel_tracer:set_current_span(otel_ctx:get_current(), SpanCtx),
    Token = otel_ctx:attach(Ctx),
    set_attributes(attrs(Data)),
    Data#data{ctx=[{SpanCtx,Token}|Stack]};
maybe_add_ctx(_, Data) ->
    Data.

get_span(#data{ctx=[{SpanCtx,_}|_]}) ->
    SpanCtx.

start_span(SpanName, Data=#data{ctx=Stack}) ->
    SpanCtx = otel_tracer:start_span(?current_tracer, SpanName, #{}),
    Ctx = otel_tracer:set_current_span(otel_ctx:get_current(), SpanCtx),
    Token = otel_ctx:attach(Ctx),
    set_attributes(attrs(Data)),
    Data#data{ctx=[{SpanCtx,Token}|Stack]};
start_span(SpanName, Data=#uninit{ctx=Stack}) ->
    SpanCtx = otel_tracer:start_span(?current_tracer, SpanName, #{}),
    Ctx = otel_tracer:set_current_span(otel_ctx:get_current(), SpanCtx),
    Token = otel_ctx:attach(Ctx),
    set_attributes(attrs(Data)),
    Data#uninit{ctx=[{SpanCtx,Token}|Stack]}.

set_attributes(Attrs) ->
    SpanCtx = otel_tracer:current_span_ctx(otel_ctx:get_current()),
    otel_span:set_attributes(SpanCtx, Attrs).

set_attribute(Attr, Val) ->
    SpanCtx = otel_tracer:current_span_ctx(otel_ctx:get_current()),
    otel_span:set_attribute(SpanCtx, Attr, Val).

end_span(Data=#data{ctx=[]}) ->
    Data;
end_span(Data=#data{ctx=[{SpanCtx,Token}|Stack]}) ->
    _ = otel_tracer:set_current_span(otel_ctx:get_current(),
                                     otel_span:end_span(SpanCtx, undefined)),
    otel_ctx:detach(Token),
    Data#data{ctx=Stack};
end_span(Data=#uninit{ctx=[]}) ->
    Data;
end_span(Data=#uninit{ctx=[{SpanCtx,Token}|Stack]}) ->
    _ = otel_tracer:set_current_span(otel_ctx:get_current(),
                                     otel_span:end_span(SpanCtx, undefined)),
    otel_ctx:detach(Token),
    Data#uninit{ctx=Stack}.

