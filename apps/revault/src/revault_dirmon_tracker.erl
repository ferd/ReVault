%%% @doc
%%% Server in charge of listening to events about a given directory and
%%% tracking all the changes in memory
%%% @end
-module(revault_dirmon_tracker).
-behviour(gen_server).
-define(VIA_GPROC(Name), {via, gproc, {n, l, {?MODULE, Name}}}).
-export([start_link/3, stop/1, file/2, files/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-opaque stamp() :: itc:event().
-export_type([stamp/0]).

%% optimization hint: replace the queue by an ordered_set ETS table?
-record(state, {
    snapshot = #{} :: #{file:filename() =>
                        {stamp(), revault_dirmon_poll:hash()}},
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

apply_operation({added, {FileName, Hash}}, SetMap, ITC) ->
    {Ct, _OldHash} = maps:get(FileName, SetMap, {undefined, Hash}),
    SetMap#{FileName => {stamp(ITC, Ct), Hash}};
apply_operation({deleted, {FileName, _Hash}}, SetMap, ITC) ->
    {Ct, _OldHash} = maps:get(FileName, SetMap),
    SetMap#{FileName := {stamp(ITC, Ct), deleted}};
apply_operation({changed, {FileName, Hash}}, SetMap, ITC) ->
    {Ct, _OldHash} = maps:get(FileName, SetMap),
    SetMap#{FileName := {stamp(ITC, Ct), Hash}}.

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
