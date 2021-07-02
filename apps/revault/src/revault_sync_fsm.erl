%%% why not just use gen_statem here and use the callbacks directly
%%% in the tests? Lift what exists already
%%%
%%%         ,----------------------,
%%%         V  ,--> client --> {client, SubState}
%%%      idle -|
%%%         ^  '--> server --> {server, SubState}
%%%         '----------------------'
%%%
%%% should be given storage and access config...
-module(revault_sync_fsm).
-behaviour(gen_statem).
-export([start_link/4, start_link/5,
         server/1, client/1, id/1, id/2, sync/2]).
-export([callback_mode/0,
         init/1, handle_event/4, terminate/3]).
-define(registry(M, N), {via, gproc, {n, l, {M, N}}}).
-define(registry(N), ?registry(?MODULE, N)).
-type name() :: string().
-record(data, {
          db_dir,
          id,
          name,
          path,
          interval,
          callback :: module() | {module(), term()},
          remote,
          caller
        }).

%  [dirs.images]
%  interval = 60
%  path = "/Users/ferd/images/"
%  ignore = [] # regexes on full path
start_link(DbDir, Name, Path, Interval) ->
    start_link(DbDir, Name, Path, Interval, revault_id_sync).

start_link(DbDir, Name, Path, Interval, Callback) ->
    gen_statem:start_link(?registry(Name), ?MODULE, {DbDir, Name, Path, Interval, Callback}, [{debug, [trace]}]).

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
    [handle_event_function].

init({DbDir, Name, Path, Interval, Callback}) ->
    process_flag(trap_exit, true),
    Id = init_id(DbDir, Name),
    {ok, idle, #data{db_dir = DbDir,
                     id = Id,
                     name = Name,
                     path = Path,
                     interval = Interval,
                     callback = Callback}}.

%handle_event(EType, EContent, {client | server, State}, Data)

%% Idle State
handle_event({call, From}, {role, client}, idle, Data) ->
    {next_state, client, Data, [{reply, From, ok}]};
%handle_event({call, _}, {role, server}, idle, Data = #data{id = undefined}) ->
%    %% TODO: initialize the server ID as new? handled in server state.
%    {next_state, idle, Data, [{reply, {error, {id, undefined}}}]};
handle_event({call, From}, {role, server}, idle, Data) ->
    {next_state, server, Data, [{reply, From, ok}]};

%% Client Mode
handle_event({call, From}, id, client, Data=#data{id=undefined}) ->
    {next_state, client, Data, [{reply, From, undefined}]};
handle_event({call, From}, id, client, Data=#data{id=Id}) ->
    {next_state, client, Data, [{reply, From, {ok, Id}}]};
handle_event({call, _From}, {id, Remote}, client, Data = #data{id = undefined}) ->
    {next_state, {client, sync_id}, Data#data{remote=Remote},
      % get an ID from a server
     [{next_event, internal, sync_id},
      % enqueue the question and respond later
      postpone]};
handle_event({call, From}, {id, _Remote}, client, Data = #data{id = Id}) ->
    {next_state, client, Data, [{reply, From, {ok, Id}}]};
%% Getting a new ID
handle_event({call, _From}, {id, _Remote}, {client, sync_id}, Data) ->
    %% Not ready yet, defer until we got a response
    {keep_state, Data, [postpone]};
handle_event(internal, sync_id, {client, sync_id},
             Data = #data{id=undefined, remote=Remote, callback=Cb}) ->
    {AskPayload, NewCb} = apply_cb(Cb, ask, []),
    {Res, FinalCb} = apply_cb(NewCb, send, [Remote, AskPayload]),
    case Res of
        {ok, _Ref} ->
            {keep_state, Data#data{callback=FinalCb}};
        {error, _R} -> %% TODO: report error
            {next_state, {client, sync_failed}, Data#data{callback=FinalCb}}
    end;
handle_event(info, {revault, _From, Payload}, {client, sync_id},
             Data=#data{name=Name, path=Path, interval=Interval,
                        callback=Cb, db_dir=Dir}) ->
    case apply_cb(Cb, unpack, [Payload]) of
        {{error, _R}, NewCb} ->
            {next_state, {client, sync_failed}, Data#data{callback=NewCb}};
        {{reply, NewId}, NewCb} ->
            ok = store_id(Dir, Name, NewId),
            %% tracker couldn't have been booted yet
            {ok, _} = start_tracker(Name, NewId, Path, Interval, Dir),
            {next_state, client, Data#data{id=NewId, callback=NewCb}}
    end;
handle_event({call, From}, {id, _Remote}, {client, sync_failed}, Data) ->
    {next_state, client, Data, [{reply, From, {error, sync_failed}}]};
handle_event({call, From}, {sync, Remote}, client,
             Data = #data{id = Id, callback=Cb0}) when Id =/= undefined ->
    %% Ask the server for its manifest
    {ManifestPayload, Cb1} = apply_cb(Cb0, manifest, []),
    {{ok, Marker}, Cb2} = apply_cb(Cb1, send, [Remote, ManifestPayload]),
    {next_state, {sync_manifest, Marker},
     Data#data{callback=Cb2, remote = Remote, caller=From}};
%% TODO: improve that Ref format
handle_event(info, {revault, _From={_,_,Ref}, Payload}, {sync_manifest, Ref},
             Data = #data{id=Id, callback=Cb0, name=Name}) ->
    {{manifest, RManifest}, Cb1} = apply_cb(Cb0, unpack, [Payload]),
    LManifest = revault_dirmon_tracker:files(Name),
    {Local, Remote} = diff_manifests(Id, LManifest, RManifest),
    Actions = schedule_file_transfers(Local, Remote),
    {next_state, {client_sync, []}, Data#data{callback=Cb1},
     Actions ++ [{next_event, internal, sync_complete}]};
handle_event(internal, {send, F}, {client_sync, Acc},
             Data=#data{name=Name, path=Path, remote=R, callback=Cb0}) ->
    {Vsn, Hash} = revault_dirmon_tracker:file(Name, F),
    %% just inefficiently read the whole freaking thing at once
    %% TODO: optimize to better read and send file parts
    {ok, Bin} = file:read_file(filename:join(Path,F)),
    {Payload, Cb1} = apply_cb(Cb0, send_file, [F, Vsn, Hash, Bin]),
    %% TODO: track failing or succeeding transfers?
    {_Ref, Cb2} = apply_cb(Cb1, send, [R, Payload]),
    {next_state, {client_sync, Acc}, Data#data{callback=Cb2}};
handle_event(internal, {fetch, F}, {client_sync, Acc},
             Data=#data{remote=R, callback=Cb0}) ->
    {Payload, Cb1} = apply_cb(Cb0, fetch_file, [F]),
    %% TODO: track incoming transfers to know when we're done syncing
    {_Ref, Cb2} = apply_cb(Cb1, send, [R, Payload]),
    {next_state, {client_sync, [F|Acc]}, Data#data{callback=Cb2}};
handle_event(internal, sync_complete, {client_sync, []},
             Data=#data{name=Name, remote=R, callback=Cb0}) ->
    %% force scan to ensure conflict files (if any) are tracked before
    %% users start modifying them. Might not be relevant when things like
    %% filesystem watchers are used, but I'm starting to like the idea of
    %% on-demand scan/sync only.
    ok = revault_dirmon_event:force_scan(Name, infinity),
    {Payload, Cb1} = apply_cb(Cb0, sync_complete, []),
    {_Ref, Cb2} = apply_cb(Cb1, send, [R, Payload]),
    {next_state, client_sync_complete_ack, Data#data{callback=Cb2}};
handle_event(internal, sync_complete, {client_sync, _Acc}, #data{}) ->
    {keep_state_and_data, [postpone]};
%% TODO: find how to constrain the 'From' here (or make it the same as the remote)
%% in order to avoid confusing the FSM with cross-talk
handle_event(info, {revault, _From, Payload}, {client_sync, Acc},
             Data=#data{name=Name, id=Id, callback=Cb0}) ->
    {Demand, Cb1} = apply_cb(Cb0, unpack, [Payload]),
    case Demand of
        {file, F, Meta, Bin} ->
            handle_file_sync(Name, Id, F, Meta, Bin),
            {next_state, {client_sync, Acc -- [F]}, Data#data{callback=Cb1}}
    end;
handle_event(info, {revault, _From, Payload}, client_sync_complete_ack,
             Data=#data{caller=From, callback=Cb0}) ->
    {Demand, Cb1} = apply_cb(Cb0, unpack, [Payload]),
    case Demand of
        sync_complete ->
            {next_state, client, Data#data{callback=Cb1}, [{reply, From, ok}]}
    end;

%% Server Mode
handle_event({call, From}, id, server,
             Data=#data{id=undefined, name=Name, path=Path, interval=Interval,
                        callback=Cb, db_dir=DbDir}) ->
    {Id, NewCb} = apply_cb(Cb, new, []),
    ok = store_id(DbDir, Name, Id),
    %% tracker couldn't have been booted yet
    {ok, _} = start_tracker(Name, Id, Path, Interval, DbDir),
    {next_state, server, Data#data{id=Id, callback=NewCb},
     [{reply, From, {ok, Id}}]};
handle_event({call, From}, id, server, #data{id=Id}) ->
    {keep_state_and_data, [{reply, From, {ok, Id}}]};
handle_event(info, {revault, From, Payload}, server,
             Data=#data{id=Id, name=Name, callback=Cb, db_dir=Dir}) when Id =/= undefined ->
    {Demand, Cb1} = apply_cb(Cb, unpack, [Payload]),
    case Demand of
        ask ->
            {{NewId, NewPayload}, Cb2} = apply_cb(Cb1, fork, [Payload, Id]),
            %% Save NewId to disk before replying to avoid issues
            ok = store_id(Dir, Name, NewId),
            %% Inject the new ID into all the local handlers before replying
            %% to avoid concurrency issues
            ok = revault_dirmon_tracker:update_id(Name, NewId),
            {_, Cb3} = apply_cb(Cb2, reply, [From, NewPayload]),
            {next_state, server, Data#data{id=NewId, callback=Cb3}};
        manifest ->
            Manifest = revault_dirmon_tracker:files(Name),
            {NewPayload, Cb2} = apply_cb(Cb1, manifest, [Manifest]),
            {_, Cb3} = apply_cb(Cb2, reply, [From, NewPayload]),
            {next_state, server_sync, Data#data{callback=Cb3}}
    end;
handle_event(info, {revault, From, Payload}, server_sync,
             Data=#data{name=Name, id=Id, callback=Cb0}) ->
    {Demand, Cb1} = apply_cb(Cb0, unpack, [Payload]),
    case Demand of
        {file, F, Meta, Bin} ->
            handle_file_sync(Name, Id, F, Meta, Bin),
            {next_state, server_sync, Data#data{callback=Cb1}};
        {conflict_file, WorkF, F, Meta, Bin} ->
            TmpF = filename:join("/tmp", F),
            filelib:ensure_dir(TmpF),
            ok = file:write_file(TmpF, Bin),
            revault_dirmon_tracker:conflict(Name, WorkF, TmpF, Meta),
            file:delete(TmpF),
            {next_state, server_sync, Data#data{callback=Cb1}};
        {fetch, F} ->
            NewData = handle_file_demand(F, From, Data#data{callback=Cb1}),
            {next_state, server_sync, NewData};
        sync_complete ->
            %% force scan to ensure conflict files (if any) are tracked before
            %% users start modifying them. Might not be relevant when things like
            %% filesystem watchers are used, but I'm starting to like the idea of
            %% on-demand scan/sync only.
            ok = revault_dirmon_event:force_scan(Name, infinity),
            {NewPayload, Cb2} = apply_cb(Cb1, sync_complete, []),
            {_, Cb3} = apply_cb(Cb2, reply, [From, NewPayload]),
            {next_state, server, Data#data{callback=Cb3}}
    end;


%% All-state
handle_event({call, From}, {role, _}, State, Data) when State =/= idle ->
    {next_state, State, Data, [{reply, From, {error, busy}}]};
handle_event(info, {revault, From, _Payload}, State, Data=#data{callback=Cb}) ->
    {NewPayload, Cb1} = apply_cb(Cb, error, [{bad_state, State, {revault, From, _Payload}}]),
    %% Save NewId to disk before replying to avoid issues
    {_, Cb2} = apply_cb(Cb1, reply, [From, NewPayload]),
    {next_state, State, Data#data{callback=Cb2}}.

terminate(_State, _Data, _Reason) ->
    % end session
    ok.

%%% PRIVATE %%%
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

%% Callback-mode, Dir is the carried state.
store_id(Dir, Name, Id) ->
    Path = filename:join([Dir, Name, "id"]),
    PathTmp = filename:join([Dir, Name, "id.tmp"]),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(PathTmp, term_to_binary(Id)),
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
%% TODO: handle conflicts
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
            diff_manifests(Id, Loc, Rem, LAcc, [{fetch, F}, RAcc])
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

handle_file_sync(Name, Id, F, Meta = {Vsn, Hash}, Bin) ->
    %% is this file a conflict or an update?
    case revault_dirmon_tracker:file(Name, F) of
        undefined ->
            update_file(Name, F, Meta, Bin);
        {LVsn, _HashOrStatus} ->
            case compare(Id, LVsn, Vsn) of
                conflict ->
                    FHash = make_conflict_path(F, Hash),
                    TmpF = filename:join("/tmp", FHash),
                    file:write_file(TmpF, Bin),
                    revault_dirmon_tracker:conflict(Name, F, TmpF, Meta),
                    file:delete(TmpF);
                _ ->
                    update_file(Name, F, Meta, Bin)
            end
    end.

update_file(Name, F, Meta, Bin) ->
    TmpF = filename:join("/tmp", F),
    filelib:ensure_dir(TmpF),
    ok = file:write_file(TmpF, Bin),
    revault_dirmon_tracker:update_file(Name, F, TmpF, Meta),
    file:delete(TmpF).

handle_file_demand(F, From, Data=#data{name=Name, path=Path, callback=Cb1}) ->
    case revault_dirmon_tracker:file(Name, F) of
        {Vsn, {conflict, Hashes, _}} ->
            %% Stream all the files, mark as conflicts?
            %% just inefficiently read the whole freaking thing at once
            %% TODO: optimize to better read and send file parts
            Cb2 = lists:foldl(
                fun(Hash, CbAcc1) ->
                    FHash = make_conflict_path(F, Hash),
                    {ok, Bin} = file:read_file(filename:join(Path, FHash)),
                    {NewPayload, CbAcc2} = apply_cb(CbAcc1, send_conflict_file, [F, FHash, Vsn, Hash, Bin]),
                    %% TODO: track failing or succeeding transfers?
                    {_Ref, CbAcc3} = apply_cb(CbAcc2, reply, [From, NewPayload]),
                    CbAcc3
                end,
                Cb1,
                Hashes
            ),
            Data#data{callback=Cb2};
        {Vsn, Hash} ->
            %% just inefficiently read the whole freaking thing at once
            %% TODO: optimize to better read and send file parts
            {ok, Bin} = file:read_file(filename:join(Path, F)),
            {NewPayload, Cb2} = apply_cb(Cb1, send_file, [F, Vsn, Hash, Bin]),
            %% TODO: track failing or succeeding transfers?
            {_Ref, Cb3} = apply_cb(Cb2, reply, [From, NewPayload]),
            Data#data{callback=Cb3}
    end.

make_conflict_path(F, Hash) ->
    F ++ "." ++ hexname(Hash).

%% TODO: extract shared definition with revault_dirmon_tracker
hex(Hash) ->
    binary:encode_hex(Hash).

%% TODO: extract shared definition with revault_dirmon_tracker
hexname(Hash) ->
    unicode:characters_to_list(string:slice(hex(Hash), 0, 8)).

compare(Id, Ct1, Ct2) ->
    ITC1 = itc:rebuild(Id, Ct1),
    ITC2 = itc:rebuild(Id, Ct2),
    case {itc:leq(ITC1, ITC2), itc:leq(ITC2, ITC1)} of
        {false, false} -> conflict;
        {true, true} -> equal;
        {true, false} -> lesser;
        {false, true} -> greater
    end.
