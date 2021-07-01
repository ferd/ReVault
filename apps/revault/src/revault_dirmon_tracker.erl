%%% @doc
%%% Server in charge of listening to events about a given directory and
%%% tracking all the changes in memory
%%% @end
-module(revault_dirmon_tracker).
-behviour(gen_server).
-define(VIA_GPROC(Name), {via, gproc, {n, l, {?MODULE, Name}}}).
-export([start_link/3, stop/1, file/2, files/1]).
-export([update_id/2, conflict/4, update_file/4, delete_file/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-opaque stamp() :: itc:event().
-export_type([stamp/0]).

%% optimization hint: replace the queue by an ordered_set ETS table?
-record(state, {
    snapshot = #{} :: #{file:filename() =>
                        {stamp(),
                         revault_dirmon_poll:hash() | deleted |
                         {conflict,
                          %% known conflicts, track for syncs
                          [revault_dirmon_poll:hash(), ...],
                          %% Last known working file; track to know what hash to
                          %% pick when resolving the conflict, but do not use in
                          %% actual conflict syncs
                          revault_dirmon_poll:hash() | deleted}
                        }},
    storage = undefined :: file:filename() | undefined,
    itc_id :: itc:id()
}).

start_link(Name, File, VsnSeed) ->
    gen_server:start_link(?VIA_GPROC(Name), ?MODULE,
                          [Name, VsnSeed, File], []).

file(Name, File) ->
    gen_server:call(?VIA_GPROC(Name), {file, File}).

files(Name) ->
    gen_server:call(?VIA_GPROC(Name), files).

stop(Name) ->
    gen_server:stop(?VIA_GPROC(Name), normal, 5000).

update_id(Name, Id) ->
    gen_server:call(?VIA_GPROC(Name), {update_id, Id}, infinity).

-spec conflict(term(), file:filename(), file:filename(),
               {stamp(), revault_dirmon_poll:hash()}) -> ok.
conflict(Name, WorkFile, ConflictFile, Vsn = {_Stamp, _Hash}) ->
    gen_server:call(?VIA_GPROC(Name), {conflict, WorkFile, ConflictFile, Vsn}, infinity).

update_file(Name, WorkFile, NewFile, Vsn = {_Stamp, _Hash}) ->
    gen_server:call(?VIA_GPROC(Name), {update_file, WorkFile, NewFile, Vsn}, infinity).

delete_file(Name, WorkFile, Vsn = {_Stamp, deleted}) ->
    gen_server:call(?VIA_GPROC(Name), {delete_file, WorkFile, Vsn}, infinity).

%%%%%%%%%%%%%%%%%
%%% CALLBACKS %%%
%%%%%%%%%%%%%%%%%

init([Name, VsnSeed, File]) ->
    Snapshot = restore_snapshot(File),
    true = gproc:reg({p, l, Name}),
    {ok, #state{
        snapshot = Snapshot,
        storage = File,
        itc_id = VsnSeed
    }}.

handle_call({file, Name}, _From, State = #state{snapshot=Map}) ->
    case Map of
        #{Name := Status} ->
            {reply, Status, State};
        _ ->
            {reply, undefined, State}
    end;
handle_call(files, _From, State = #state{snapshot=Map}) ->
    {reply, Map, State};
handle_call({update_id, ITC}, _From, State = #state{}) ->
    NewState = State#state{itc_id = ITC},
    %% The snapshot currently does not contain ITCs, but do save anyway
    %% in case we eventually do; can't hurt anything but perf.
    save_snapshot(NewState),
    {reply, ok, NewState};
handle_call({conflict, Work, Conflict, {NewStamp, NewHash}}, _From,
            State = #state{snapshot=Map, itc_id=Id}) ->
    NewConflict = case Map of
        #{Work := {Stamp, {conflict, ConflictHashes, WorkingHash}}} ->
            %% A conflict already existed; add to it.
            case lists:member(NewHash, ConflictHashes) of
                true ->
                    CStamp = conflict_stamp(Id, Stamp, NewStamp),
                    {CStamp, {conflict, ConflictHashes, WorkingHash}};
                false ->
                    ConflictingFile = Work ++ "." ++ hexname(NewHash),
                    %% TODO: use a copy+rename to avoid corrupting files mid-crash
                    {ok, _} = file:copy(Conflict, ConflictingFile),
                    NewHashes = lists:sort([NewHash|ConflictHashes]),
                    CStamp = conflict_stamp(Id, Stamp, NewStamp),
                    {CStamp, {conflict, NewHashes, WorkingHash}}
            end;
        #{Work := {Stamp, WorkingHash}} ->
            %% No conflict, create it
            ConflictingFile = Work ++ "." ++ hexname(NewHash),
            %% TODO: use a copy+rename to avoid corrupting files mid-crash
            {ok, _} = file:copy(Conflict, ConflictingFile),
            NewHashes = [NewHash],
            CStamp = conflict_stamp(Id, Stamp, NewStamp),
            {CStamp, {conflict, NewHashes, WorkingHash}};
        _ when not is_map_key(Work, Map) ->
            %% No file, create a conflict
            ConflictingFile = Work ++ "." ++ hexname(NewHash),
            %% TODO: use a copy+rename to avoid corrupting files mid-crash
            {ok, _} = file:copy(Conflict, ConflictingFile),
            {NewStamp, {conflict, [NewHash], NewHash}}
    end,
    NewState = State#state{snapshot=Map#{Work => NewConflict}},
    ok = write_conflict_file(Work, NewConflict),
    save_snapshot(NewState),
    {reply, ok, NewState};
handle_call({update_file, Work, Source, {NewStamp, NewHash}}, _From,
            State = #state{snapshot=Map, itc_id=Id}) ->
    case Map of
        #{Work := {Stamp, {conflict, Hashes, _}}} ->
            case compare(Id, Stamp, NewStamp) of
                equal -> % this doesn't make sense
                    error({stamp_shared_for_conflicting_operations,
                           {Stamp, conflict}, {NewStamp, update_file}});
                lesser -> % sync resolves conflict
                    %% TODO: use a copy+rename to avoid corrupting files mid-crash
                    {ok, _} = file:copy(Source, Work),
                    resolve_conflict(Work, Hashes),
                    delete_conflict_file(Work),
                    NewState = State#state{snapshot=Map#{Work => {NewStamp, NewHash}}},
                    save_snapshot(NewState),
                    {reply, ok, NewState};
                greater -> % sync outdated
                    {reply, ok, State};
                conflict ->
                    handle_call({conflict, Work, Source, {NewStamp, NewHash}}, _From, State)
            end;
        #{Work := {Stamp, _WorkingHash}} ->
            case compare(Id, Stamp, NewStamp) of
                conflict ->
                    handle_call({conflict, Work, Source, {NewStamp, NewHash}}, _From, State);
                lesser ->
                    %% TODO: use a copy+rename to avoid corrupting files mid-crash
                    {ok, _} = file:copy(Source, Work),
                    NewState = State#state{snapshot=Map#{Work => {NewStamp, NewHash}}},
                    save_snapshot(NewState),
                    {reply, ok, NewState};
                _ -> % current file is newer or equal to the proposed one
                    {reply, ok, State}
            end;
        _ when not is_map_key(Work, Map) ->
            %% TODO: use a copy+rename to avoid corrupting files mid-crash
            {ok, _} = file:copy(Source, Work),
            NewState = State#state{snapshot=Map#{Work => {NewStamp, NewHash}}},
            save_snapshot(NewState),
            {reply, ok, NewState}
    end;
handle_call({delete_file, Work, {NewStamp, deleted}}, _From,
            State = #state{snapshot=Map, itc_id=Id}) ->
    case Map of
        #{Work := {Stamp, {conflict, Hashes, _}}} ->
            case compare(Id, Stamp, NewStamp) of
                equal -> % this doesn't make sense
                    error({stamp_shared_for_conflicting_operations,
                           {Stamp, conflict}, {NewStamp, delete_file}});
                lesser -> % sync resolves conflict
                    _ = file:delete(Work),
                    resolve_conflict(Work, Hashes),
                    delete_conflict_file(Work),
                    NewState = State#state{snapshot=Map#{Work => {NewStamp, deleted}}},
                    save_snapshot(NewState),
                    {reply, ok, NewState};
                greater -> % sync outdated
                    {reply, ok, State};
                conflict -> % already gone from the current conflict?
                    {reply, ok, State}
            end;
        #{Work := {Stamp, _WorkingHash}} ->
            case compare(Id, Stamp, NewStamp) of
                conflict -> % it's already gone from the current conflict?
                    {reply, ok, State};
                lesser ->
                    _ = file:delete(Work),
                    NewState = State#state{snapshot=Map#{Work => {NewStamp, deleted}}},
                    save_snapshot(NewState),
                    {reply, ok, NewState};
                _ -> % current file is newer or equal to the proposed one
                    {reply, ok, State}
            end;
        _ when not is_map_key(Work, Map) ->
            NewState = State#state{snapshot=Map#{Work => {NewStamp, deleted}}},
            save_snapshot(NewState),
            {reply, ok, NewState}
    end;
handle_call(_Call, _From, State) ->
    {noreply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({dirmon, _Name, {Transform, _} = Op},
            State=#state{snapshot=Map, itc_id = ITC})
        when Transform == deleted;
             Transform == added;
             Transform == changed ->
    NewState = State#state{snapshot = apply_operation(Op, Map, ITC)},
    %% TODO: save a snapshot on inactivity rather than each change?
    save_snapshot(NewState),
    {noreply, NewState};
handle_info(_Msg, State) ->
    {noreply, State}.

stamp(Id, Ct) ->
    ITC = itc:rebuild(Id, Ct),
    {_Id, NewCt} = itc:explode(itc:event(ITC)),
    NewCt.

compare(Id, Ct1, Ct2) ->
    ITC1 = itc:rebuild(Id, Ct1),
    ITC2 = itc:rebuild(Id, Ct2),
    case {itc:leq(ITC1, ITC2), itc:leq(ITC2, ITC1)} of
        {false, false} -> conflict;
        {true, true} -> equal;
        {true, false} -> lesser;
        {false, true} -> greater
    end.

apply_operation({added, {FileName, Hash}}, SetMap, ITC) ->
    case get_file(FileName, SetMap) of
        {ok, {_Ct, Hash}} -> % same hash, clash on sync-updated file
            SetMap;
        {ok, {Ct, _OldHash}} ->
            SetMap#{FileName => {stamp(ITC, Ct), Hash}};
        {conflict, {Ct, {conflict, Hashes, _OldHash}}} ->
            SetMap#{FileName => {Ct, {conflict, Hashes, Hash}}};
        unknown ->
            SetMap#{FileName => {stamp(ITC, undefined), Hash}};
        _ ->
            SetMap
    end;
apply_operation({deleted, {FileName, Hash}}, SetMap, ITC) ->
    case get_file(FileName, SetMap) of
        {ok, {_, deleted}} -> % already gone, clash on sync-updated file
            SetMap;
        {ok, {Ct, _OldHash}} ->
            SetMap#{FileName => {stamp(ITC, Ct), deleted}};
        {conflict, {Ct, {conflict, Hashes, _OldHash}}} ->
            SetMap#{FileName => {Ct, {conflict, Hashes, deleted}}};
        {marker, BaseFile, {Ct, {conflict, Hashes, WorkingHash}}} ->
            %% conflict resolved. clear trailing conflicting files
            resolve_conflict(BaseFile, Hashes),
            SetMap#{BaseFile => {stamp(ITC, Ct), WorkingHash}};
        {conflicting, BaseFile, {Ct, {conflict, Hashes, WorkingHash}}} ->
            write_conflict_file(BaseFile, {Ct, {conflict, Hashes, WorkingHash}}),
            SetMap#{BaseFile => {Ct, {conflict, Hashes--[Hash], WorkingHash}}};
        conflict_extension ->
            SetMap
    end;
apply_operation({changed, {FileName, Hash}}, SetMap, ITC) ->
    case get_file(FileName, SetMap) of
        {ok, {_Ct, Hash}} -> % same hash, clash on sync-updated file
            SetMap;
        {ok, {Ct, _OldHash}} ->
            SetMap#{FileName => {stamp(ITC, Ct), Hash}};
        {conflict, {Ct, {conflict, Hashes, _OldHash}}} ->
            SetMap#{FileName => {Ct, {conflict, Hashes, Hash}}};
        _ ->
            SetMap
    end.

restore_snapshot(File) ->
    case file:consult(File) of
        {error, enoent} ->
            #{};
        {ok, [Snapshot]} ->
            Snapshot
    end.

save_snapshot(#state{storage = undefined}) ->
    %% diskless mode
    ok;
save_snapshot(#state{snapshot = Snap, storage = File}) ->
    %% 1. write the file to a temporary file
    %% 2. confirm it is good
    %% 3. rename the file to the canonical name
    %%
    %% rename is atomic in POSIX file systems so we prevent corrupting
    %% the snapshot on a failure on a halfway write, but both files
    %% should be in the same directory so that we don't accidentally
    %% end up on two distinct filesystems, which then blocks renaming
    %% from working.
    RandVal = float_to_list(rand:uniform()),
    SnapshotName = File ++ RandVal,
    SnapshotBlob = unicode:characters_to_binary(
        io_lib:format("~tp.~n", [Snap])
    ),
    ok = file:write_file(SnapshotName, SnapshotBlob, [sync]),
    ok = file:rename(SnapshotName, File).

write_conflict_file(WorkingFile, {_, {conflict, Hashes, _}}) ->
    %% We don't care about the rename trick here, it's informational
    %% but all the critical data is tracked in the snapshot
    file:write_file(
        WorkingFile ++ ".conflict",
        lists:join($\n, [hex(Hash) || Hash <- Hashes])
    ).

delete_conflict_file(WorkingFile) ->
    file:delete(WorkingFile ++ ".conflict").

hex(Hash) ->
    binary:encode_hex(Hash).

hexname(Hash) ->
    unicode:characters_to_list(string:slice(hex(Hash), 0, 8)).

conflict_stamp(Id, C1, C2) ->
    %% Merge all things, potential conflicts are handled by merging all
    %% conflict info in parent calls.
    NewClock = itc:join(itc:rebuild(Id,C1), itc:peek(itc:rebuild(Id, C2))),
    {_, Stamp} = itc:explode(NewClock),
    Stamp.

get_file(FileName, SetMap) ->
    case maps:find(FileName, SetMap) of
        {ok, {Ct, {conflict, Hashes, Hash}}} ->
            {conflict, {Ct, {conflict, Hashes, Hash}}};
        {ok, {Ct, Hash}} ->
            {ok, {Ct, Hash}};
        error ->
            case conflict_ext(FileName, filename:extension(FileName), SetMap) of
                false -> unknown;
                Other -> Other
            end
    end.

conflict_ext(File, ".conflict", Map) ->
    BasePath = drop_suffix(File, ".conflict"),
    case maps:find(BasePath, Map) of
        {ok, {Ct, Conflict = {conflict, _, _}}} ->
            {marker, BasePath, {Ct, Conflict}};
        _ -> conflict_extension
    end;
conflict_ext(File, Ext, Map) ->
    case length(Ext) == 9 andalso is_hex(tl(Ext)) of
        true ->
            BasePath = drop_suffix(File, Ext),
            case maps:find(BasePath, Map) of
                {ok, {Ct, Conflict = {conflict, _, _}}} ->
                    {conflicting, BasePath, {Ct, Conflict}};
                _ -> conflict_extension
            end;
        false ->
            false
    end.

drop_suffix(Suffix, Suffix) -> [];
drop_suffix([H|T], Suffix) -> [H|drop_suffix(T, Suffix)].

is_hex([C]) when C >= $A, C =< $F; C >= $0, C =< $9 -> true;
is_hex([C|T]) when C >= $A, C =< $F; C >= $0, C =< $9 -> is_hex(T);
is_hex(L) when is_list(L) -> false.

resolve_conflict(BaseFile, Hashes) ->
    [file:delete(BaseFile ++ "." ++ hexname(ConflictHash))
     || ConflictHash <- Hashes],
    ok.
