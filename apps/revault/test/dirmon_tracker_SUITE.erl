-module(dirmon_tracker_SUITE).
-compile(export_all).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [{group, update},
     {group, delete},
     conflict_creation,
     {group, conflict_resolution}].

groups() ->
    [{conflict_resolution, [], [
        conflict_resolution_orderly,
        conflict_resolution_orderly_deleted,
        conflict_resolution_marker_first,
        conflict_resolution_drop_conflict
     ]},
     {update, [], [
        update_file,
        update_new,
        update_older,
        update_conflict,
        update_conflict_resolve,
        update_conflict_older
     ]},
     {delete, [], [
        delete_file,
        delete_new,
        delete_older,
        delete_conflict,
        delete_conflict_resolve,
        delete_conflict_older
     ]}
    ].

    %% TODO: do the thing where you delete the conflict file first and then drop the hashes
    %%       although that wouldn't be needed.
    %% TODO: do the thing where a conflict candidate is dropped and make sure it's removed
    %%       from the tracked file
    %% TODO: weird ass things like moving conflicting files around

init_per_testcase(Name, Config) ->
    {ok, Apps} = application:ensure_all_started(gproc),
    FilesDir = filename:join([?config(priv_dir, Config), "files"]),
    StoreDir = filename:join([?config(priv_dir, Config), "store"]),
    TmpDir = filename:join([?config(priv_dir, Config), "tmp"]),
    ok = filelib:ensure_dir(filename:join([FilesDir, ".touch"])),
    ok = filelib:ensure_dir(filename:join([StoreDir, ".touch"])),
    ok = filelib:ensure_dir(filename:join([TmpDir, ".touch"])),
    {ok, Tracker} = revault_dirmon_tracker:start_link(
        Name,
        filename:join([StoreDir, "snapshot"]),
        revault_id:new()
    ),
    {ok, Event} = revault_dirmon_event:start_link(
        Name,
        #{directory => FilesDir,
          initial_sync => tracker,
          poll_interval => 6000000} % too long to interfere
    ),
    [{name, Name}, {tracker, Tracker}, {event, Event}, {apps, Apps},
     {files_dir, FilesDir}, {tmp_dir, TmpDir}, {store_dir, StoreDir} | Config].

end_per_testcase(_, Config) ->
    gen_server:stop(?config(event, Config)),
    gen_server:stop(?config(tracker, Config)),
    [application:stop(App) || App <- lists:reverse(?config(apps, Config))],
    Config.

conflict_creation() ->
    [{doc, "A conflict can be created with nothing but the existing file "
           "already in place. A conflict where a file is deleted on one host "
           "and modified on another should result in a single-file conflict "
           "that isn't resolved. "
           "A conflict marker file (containing the hashes "
           "of all conflicting files) is created. Additionally, each "
           "conflicting file are tracked by the conflict marker, which is "
           "part of the tracker's database such that conflicting conflicts "
           "are detected. Finally, the actual working file is not updated "
           "anymore from the point the marker is active"}].
conflict_creation(Config) ->
    Name = ?config(name, Config),
    Dir = ?config(files_dir, Config),
    TmpFile = filename:join([?config(tmp_dir, Config), "work"]),
    WorkFile = filename:join([Dir, "work"]),
    ConflictMarker = filename:join([Dir, "work.conflict"]),
    ConflictA = filename:join([Dir, "work." ++ hexname("a")]),
    ConflictB = filename:join([Dir, "work." ++ hexname("b")]),
    %% Set up the basic files
    ok = file:write_file(WorkFile, <<"a">>),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    #{WorkFile := {Vsn1, HashA}} = revault_dirmon_tracker:files(Name),
    ?assertEqual(HashA, hash(<<"a">>)),
    %% Create the one-file conflict
    ok = revault_dirmon_tracker:conflict(Name, WorkFile, WorkFile, {Vsn1, HashA}),
    ?assertEqual({ok, <<"a">>}, file:read_file(WorkFile)),
    ?assertEqual({ok, <<"a">>}, file:read_file(ConflictA)),
    ?assertEqual({ok, hex(<<"a">>)}, file:read_file(ConflictMarker)),
    %% Add more conflict files
    ok = file:write_file(TmpFile, <<"b">>),
    ok = revault_dirmon_tracker:conflict(Name, WorkFile, TmpFile, {Vsn1, hash(<<"b">>)}),
    ?assertEqual({ok, <<"a">>}, file:read_file(WorkFile)),
    ?assertEqual({ok, <<"a">>}, file:read_file(ConflictA)),
    ?assertEqual({ok, <<"b">>}, file:read_file(ConflictB)),
    ?assertEqual({ok, iolist_to_binary([
            %% per-hash alphabetical order
            hex(<<"b">>), "\n", hex(<<"a">>)
        ])},
        file:read_file(ConflictMarker)
    ),
    %% Check that changes to the working file aren't picked up
    {Stamp1, {conflict, Hs, WHash1}} = revault_dirmon_tracker:file(Name, WorkFile),
    ?assertEqual(hash(<<"a">>), WHash1),
    ok = file:write_file(WorkFile, <<"b">>),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    {Stamp2, ConflictData} = revault_dirmon_tracker:file(Name, WorkFile),
    ?assertEqual(Stamp1, Stamp2),
    ?assertEqual({conflict, Hs, hash(<<"b">>)}, ConflictData),
    %% Conflict files are _not_ tracked independently
    ?assertEqual(undefined, revault_dirmon_tracker:file(Name, ConflictMarker)),
    ?assertEqual(undefined, revault_dirmon_tracker:file(Name, ConflictA)),
    ?assertEqual(undefined, revault_dirmon_tracker:file(Name, ConflictB)),
    ok.


conflict_resolution_orderly() ->
    [{doc, "A conflict can be resolved by removing each conflicting file "
           "until only the final file and the conflict marker are left. "
           "Removing the conflict marker then finalizes the working file "
           "as non-conflicting with a bumped version."}].
conflict_resolution_orderly(Config) ->
    Name = ?config(name, Config),
    Dir = ?config(files_dir, Config),
    TmpFile = filename:join([?config(tmp_dir, Config), "work"]),
    WorkFile = filename:join([Dir, "work"]),
    ConflictMarker = filename:join([Dir, "work.conflict"]),
    ConflictA = filename:join([Dir, "work." ++ hexname("a")]),
    ConflictB = filename:join([Dir, "work." ++ hexname("b")]),
    %% Set up the basic files
    ok = file:write_file(WorkFile, <<"a">>),
    ok = file:write_file(TmpFile, <<"b">>),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    #{WorkFile := {Vsn1, HashA}} = revault_dirmon_tracker:files(Name),
    %% Create conflicts
    ok = revault_dirmon_tracker:conflict(Name, WorkFile, WorkFile, {Vsn1, HashA}),
    ok = revault_dirmon_tracker:conflict(Name, WorkFile, TmpFile, {Vsn1, hash(<<"b">>)}),
    ?assertEqual({ok, <<"a">>}, file:read_file(WorkFile)),
    ?assertEqual({ok, <<"a">>}, file:read_file(ConflictA)),
    ?assertEqual({ok, <<"b">>}, file:read_file(ConflictB)),
    %% Clear conflicting files one at a time
    ok = file:delete(ConflictA),
    ok = file:delete(ConflictB),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    ?assertEqual({ok, <<"a">>}, file:read_file(WorkFile)),
    ?assertEqual({ok, iolist_to_binary([
            hex(<<"b">>), "\n", hex(<<"a">>)
        ])},
        file:read_file(ConflictMarker)
    ),
    ok = file:write_file(WorkFile, <<"b">>),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    ok = file:delete(ConflictMarker),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    #{WorkFile := {Vsn2, HashB}} = revault_dirmon_tracker:files(Name),
    ?assertEqual(HashB, hash(<<"b">>)),
    ?assertNotEqual(Vsn1, Vsn2),
    ok.

conflict_resolution_orderly_deleted() ->
    [{doc, "Same as `conflict_resolution_orderly' but with a resolution "
           "based on file deletion."}].
conflict_resolution_orderly_deleted(Config) ->
    Name = ?config(name, Config),
    Dir = ?config(files_dir, Config),
    TmpFile = filename:join([?config(tmp_dir, Config), "work"]),
    WorkFile = filename:join([Dir, "work"]),
    ConflictMarker = filename:join([Dir, "work.conflict"]),
    ConflictA = filename:join([Dir, "work." ++ hexname("a")]),
    ConflictB = filename:join([Dir, "work." ++ hexname("b")]),
    %% Set up the basic files
    ok = file:write_file(WorkFile, <<"a">>),
    ok = file:write_file(TmpFile, <<"b">>),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    #{WorkFile := {Vsn1, HashA}} = revault_dirmon_tracker:files(Name),
    %% Create conflicts
    ok = revault_dirmon_tracker:conflict(Name, WorkFile, WorkFile, {Vsn1, HashA}),
    ok = revault_dirmon_tracker:conflict(Name, WorkFile, TmpFile, {Vsn1, hash(<<"b">>)}),
    ?assertEqual({ok, <<"a">>}, file:read_file(WorkFile)),
    ?assertEqual({ok, <<"a">>}, file:read_file(ConflictA)),
    ?assertEqual({ok, <<"b">>}, file:read_file(ConflictB)),
    %% Clear conflicting files one at a time
    ok = file:delete(ConflictA),
    ok = file:delete(ConflictB),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    ?assertEqual({ok, <<"a">>}, file:read_file(WorkFile)),
    ?assertEqual({ok, iolist_to_binary([
            hex(<<"b">>), "\n", hex(<<"a">>)
        ])},
        file:read_file(ConflictMarker)
    ),
    ok = file:write_file(WorkFile, <<"b">>),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    ok = file:delete(WorkFile),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    ?assertMatch(#{WorkFile := {Vsn1, {conflict, _, deleted}}},
                 revault_dirmon_tracker:files(Name)),
    ok = file:delete(ConflictMarker),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    ?assertMatch(#{WorkFile := {_, deleted}},
                 revault_dirmon_tracker:files(Name)),
    ok.

conflict_resolution_marker_first() ->
    [{doc, "Dropping the conflict marker should instantly declare the working "
           "file as resolved. It would be awfully nice to then auto-delete the "
           "conflicting files."}].
conflict_resolution_marker_first(Config) ->
    Name = ?config(name, Config),
    Dir = ?config(files_dir, Config),
    TmpFile = filename:join([?config(tmp_dir, Config), "work"]),
    WorkFile = filename:join([Dir, "work"]),
    ConflictMarker = filename:join([Dir, "work.conflict"]),
    ConflictA = filename:join([Dir, "work." ++ hexname("a")]),
    ConflictB = filename:join([Dir, "work." ++ hexname("b")]),
    %% Set up the basic files
    ok = file:write_file(WorkFile, <<"a">>),
    ok = file:write_file(TmpFile, <<"b">>),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    #{WorkFile := {Vsn1, HashA}} = revault_dirmon_tracker:files(Name),
    %% Create conflicts
    ok = revault_dirmon_tracker:conflict(Name, WorkFile, WorkFile, {Vsn1, HashA}),
    ok = revault_dirmon_tracker:conflict(Name, WorkFile, TmpFile, {Vsn1, hash(<<"b">>)}),
    ?assertEqual({ok, <<"a">>}, file:read_file(WorkFile)),
    ?assertEqual({ok, <<"a">>}, file:read_file(ConflictA)),
    ?assertEqual({ok, <<"b">>}, file:read_file(ConflictB)),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    %% Clear conflict marker and see what goes
    ok = file:delete(ConflictMarker),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    #{WorkFile := {Vsn2, HashA}} = revault_dirmon_tracker:files(Name),
    ?assertNotEqual(Vsn1, Vsn2),
    ?assertEqual({ok, <<"a">>}, file:read_file(WorkFile)),
    ?assertEqual({error, enoent}, file:read_file(ConflictA)),
    ?assertEqual({error, enoent}, file:read_file(ConflictB)),
    ok.

conflict_resolution_drop_conflict() ->
    [{doc, "Deleting the conflict marker and the working files results in the "
           "conflict resolving in a deletion. Conflicting files are dropped as well."}].
conflict_resolution_drop_conflict(Config) ->
    Name = ?config(name, Config),
    Dir = ?config(files_dir, Config),
    TmpFile = filename:join([?config(tmp_dir, Config), "work"]),
    WorkFile = filename:join([Dir, "work"]),
    ConflictMarker = filename:join([Dir, "work.conflict"]),
    ConflictA = filename:join([Dir, "work." ++ hexname("a")]),
    ConflictB = filename:join([Dir, "work." ++ hexname("b")]),
    %% Set up the basic files
    ok = file:write_file(WorkFile, <<"a">>),
    ok = file:write_file(TmpFile, <<"b">>),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    #{WorkFile := {Vsn1, HashA}} = revault_dirmon_tracker:files(Name),
    %% Create conflicts
    ok = revault_dirmon_tracker:conflict(Name, WorkFile, WorkFile, {Vsn1, HashA}),
    ok = revault_dirmon_tracker:conflict(Name, WorkFile, TmpFile, {Vsn1, hash(<<"b">>)}),
    ?assertEqual({ok, <<"a">>}, file:read_file(WorkFile)),
    ?assertEqual({ok, <<"a">>}, file:read_file(ConflictA)),
    ?assertEqual({ok, <<"b">>}, file:read_file(ConflictB)),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    %% Clear conflict marker and workfile within the same scan
    ok = file:delete(WorkFile),
    ok = file:delete(ConflictMarker),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    #{WorkFile := {Vsn2, deleted}} = revault_dirmon_tracker:files(Name),
    ?assertNotEqual(Vsn1, Vsn2),
    ?assertEqual({error, enoent}, file:read_file(WorkFile)),
    ?assertEqual({error, enoent}, file:read_file(ConflictA)),
    ?assertEqual({error, enoent}, file:read_file(ConflictB)),
    ok.

update_file() ->
    [{doc, "A file coming from another server needs to be updated in a way "
           "that is aware of the remote version, and not just of the file "
           "getting modified on disk. "
           "This can be handled by asking the tracker to directly upsert "
           "the file in the tracked directory with the contents of one "
           "located elsewhere in the filesystem (e.g.: /tmp) while "
           "bumping its version and ensuring that there is no clash with "
           "the scanner."}].
update_file(Config) ->
    Name = ?config(name, Config),
    Dir = ?config(files_dir, Config),
    TmpFile = filename:join([?config(tmp_dir, Config), "work"]),
    WorkFile = filename:join([Dir, "work"]),
    ok = file:write_file(WorkFile, <<"a">>),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    #{WorkFile := {VsnA, HashA}} = revault_dirmon_tracker:files(Name),
    ?assertEqual(HashA, hash(<<"a">>)),
    %% Create the remote file to merge
    ok = file:write_file(TmpFile, <<"b">>),
    %% cheating with internals
    {_, IdB} = revault_id:fork(revault_id:new()),
    {_, VsnB} = itc:explode(itc:event(itc:rebuild(IdB, VsnA))),
    ok = revault_dirmon_tracker:update_file(Name, WorkFile, TmpFile, {VsnB, hash(<<"b">>)}),
    ?assertEqual({ok, <<"b">>}, file:read_file(WorkFile)),
    %% Check that changes in version are picked up properly
    {Stamp1, HashB} = revault_dirmon_tracker:file(Name, WorkFile),
    ?assertEqual(hash(<<"b">>), HashB),
    ?assert(itc:leq(itc:rebuild(IdB, VsnB), itc:rebuild(IdB, Stamp1))),
    ?assert(itc:leq(itc:rebuild(IdB, VsnA), itc:rebuild(IdB, Stamp1))),
    %% Check that the change isn't picked more than once
    ok = revault_dirmon_event:force_scan(Name, 5000),
    ?assertEqual({Stamp1, HashB}, revault_dirmon_tracker:file(Name, WorkFile)),
    ok.

update_new() ->
    [{doc, "A file coming from another server that does not exist locally "
           "is merged in a way that does not re-stamp the file to avoid "
           "the scanner re-detecting it and amplifying re-syncs with "
           "other peers."}].
update_new(Config) ->
    Name = ?config(name, Config),
    Dir = ?config(files_dir, Config),
    TmpFile = filename:join([?config(tmp_dir, Config), "work"]),
    WorkFile = filename:join([Dir, "work"]),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    %% Create the remote file to merge
    ok = file:write_file(TmpFile, <<"b">>),
    %% cheating with internals
    {_, IdB} = revault_id:fork(revault_id:new()),
    {_, VsnB} = itc:explode(itc:event(itc:rebuild(IdB, undefined))),
    ok = revault_dirmon_tracker:update_file(Name, WorkFile, TmpFile, {VsnB, hash(<<"b">>)}),
    ?assertEqual({ok, <<"b">>}, file:read_file(WorkFile)),
    %% Check that changes in version are picked up properly
    {Stamp1, HashB} = revault_dirmon_tracker:file(Name, WorkFile),
    ?assertEqual(hash(<<"b">>), HashB),
    ?assert(itc:leq(itc:rebuild(IdB, VsnB), itc:rebuild(IdB, Stamp1))),
    ?assert(itc:leq(itc:rebuild(IdB, Stamp1), itc:rebuild(IdB, VsnB))),
    ?assertEqual(Stamp1, VsnB),
    %% Check that the change isn't picked more than once
    ok = revault_dirmon_event:force_scan(Name, 5000),
    ?assertEqual({Stamp1, HashB}, revault_dirmon_tracker:file(Name, WorkFile)),
    ok.

update_older() ->
    [{doc, "Updating a file with an older one ignores any changes since the "
           "newer file wins."}].
update_older(Config) ->
    Name = ?config(name, Config),
    Dir = ?config(files_dir, Config),
    TmpFile = filename:join([?config(tmp_dir, Config), "work"]),
    WorkFile = filename:join([Dir, "work"]),
    ok = file:write_file(WorkFile, <<"a">>),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    #{WorkFile := {VsnA, HashA}} = revault_dirmon_tracker:files(Name),
    ?assertEqual(HashA, hash(<<"a">>)),
    ok = file:write_file(WorkFile, <<"b">>),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    #{WorkFile := {VsnB, HashB}} = revault_dirmon_tracker:files(Name),
    ?assertEqual(HashB, hash(<<"b">>)),
    %% Create the remote file to merge
    ok = file:write_file(TmpFile, <<"a">>),
    %% merge and see it ignored
    ok = revault_dirmon_tracker:update_file(Name, WorkFile, TmpFile, {VsnA, hash(<<"a">>)}),
    ?assertEqual({ok, <<"b">>}, file:read_file(WorkFile)),
    %% Check that changes in version are picked up properly
    {Stamp1, HashB} = revault_dirmon_tracker:file(Name, WorkFile),
    ?assertEqual(hash(<<"b">>), HashB),
    ?assertEqual(VsnB, Stamp1),
    %% Check that the change isn't picked more than once
    ok = revault_dirmon_event:force_scan(Name, 5000),
    ?assertEqual({Stamp1, HashB}, revault_dirmon_tracker:file(Name, WorkFile)),
    ok.

update_conflict() ->
    [{doc, "Syncing a disjoint update into a conflict results in the "
           "update being in the conflict."}].
update_conflict(Config) ->
    Name = ?config(name, Config),
    Dir = ?config(files_dir, Config),
    TmpFile = filename:join([?config(tmp_dir, Config), "work"]),
    TmpFileUp = filename:join([?config(tmp_dir, Config), "up"]),
    WorkFile = filename:join([Dir, "work"]),
    ConflictMarker = filename:join([Dir, "work.conflict"]),
    ConflictA = filename:join([Dir, "work." ++ hexname("a")]),
    ConflictB = filename:join([Dir, "work." ++ hexname("b")]),
    ConflictC = filename:join([Dir, "work." ++ hexname("c")]),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    %% Create the remote files to merge
    ok = file:write_file(TmpFile, <<"b">>),
    ok = file:write_file(TmpFileUp, <<"c">>),
    %% cheating with internals
    {IdA, IdB} = revault_id:fork(revault_id:new()),
    {_, IdC} = revault_id:fork(IdA),
    {_, VsnB} = itc:explode(itc:event(itc:rebuild(IdB, undefined))),
    {_, VsnC} = itc:explode(itc:event(itc:rebuild(IdC, undefined))),
    ok = revault_dirmon_tracker:conflict(Name, WorkFile, TmpFile, {VsnB, hash(<<"b">>)}),
    ?assertMatch({ok, _}, file:read_file(ConflictMarker)),
    ?assertMatch({error, enoent}, file:read_file(ConflictA)), % created on opposed end sync
    ?assertMatch({ok, _}, file:read_file(ConflictB)),
    ?assertMatch({error, enoent}, file:read_file(ConflictC)),
    %% Using an update with a newer version resolves the conflict and cleares files
    ok = revault_dirmon_tracker:conflict(Name, WorkFile, TmpFileUp, {VsnC, hash(<<"c">>)}),
    ?assertMatch({ok, _}, file:read_file(ConflictMarker)),
    ?assertMatch({error, enoent}, file:read_file(ConflictA)), % created on opposed end sync
    ?assertMatch({ok, _}, file:read_file(ConflictB)),
    ?assertMatch({ok, _}, file:read_file(ConflictC)),
    ok.

update_conflict_resolve() ->
    [{doc, "Syncing a recent update into a conflict results in the "
           "conflict resolving. Conflicting files are dropped as well."}].
update_conflict_resolve(Config) ->
    Name = ?config(name, Config),
    Dir = ?config(files_dir, Config),
    TmpFile = filename:join([?config(tmp_dir, Config), "work"]),
    TmpFileUp = filename:join([?config(tmp_dir, Config), "up"]),
    WorkFile = filename:join([Dir, "work"]),
    ConflictMarker = filename:join([Dir, "work.conflict"]),
    ConflictA = filename:join([Dir, "work." ++ hexname("a")]),
    ConflictB = filename:join([Dir, "work." ++ hexname("b")]),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    %% Create the remote files to merge
    ok = file:write_file(TmpFile, <<"b">>),
    ok = file:write_file(TmpFileUp, <<"c">>),
    %% cheating with internals
    {_, IdB} = revault_id:fork(revault_id:new()),
    {_, VsnB} = itc:explode(itc:event(itc:rebuild(IdB, undefined))),
    {_, VsnC} = itc:explode(itc:event(itc:rebuild(IdB, VsnB))),
    ok = revault_dirmon_tracker:conflict(Name, WorkFile, TmpFile, {VsnB, hash(<<"b">>)}),
    ?assertMatch({ok, _}, file:read_file(ConflictMarker)),
    ?assertMatch({error, enoent}, file:read_file(ConflictA)), % created on opposed end sync
    ?assertMatch({ok, _}, file:read_file(ConflictB)),
    %% Using an update with a newer version resolves the conflict and cleares files
    ok = revault_dirmon_tracker:update_file(Name, WorkFile, TmpFileUp, {VsnC, hash(<<"c">>)}),
    {Stamp1, HashC} = revault_dirmon_tracker:file(Name, WorkFile),
    ?assertEqual({error, enoent}, file:read_file(ConflictMarker)),
    ?assertEqual({error, enoent}, file:read_file(ConflictB)),
    ?assertEqual(hash(<<"c">>), HashC),
    ?assert(itc:leq(itc:rebuild(IdB, VsnC), itc:rebuild(IdB, Stamp1))),
    ?assert(itc:leq(itc:rebuild(IdB, Stamp1), itc:rebuild(IdB, VsnC))),
    ?assertEqual(Stamp1, VsnC),
    %% Check that the change isn't picked more than once
    ok = revault_dirmon_event:force_scan(Name, 5000),
    ?assertEqual({Stamp1, HashC}, revault_dirmon_tracker:file(Name, WorkFile)),
    ok.

update_conflict_older() ->
    [{doc, "Syncing an old update into a newer conflict results in the "
           "update being ignored"}].
update_conflict_older(Config) ->
    Name = ?config(name, Config),
    Dir = ?config(files_dir, Config),
    TmpFile = filename:join([?config(tmp_dir, Config), "work"]),
    TmpFileUp = filename:join([?config(tmp_dir, Config), "up"]),
    WorkFile = filename:join([Dir, "work"]),
    ConflictMarker = filename:join([Dir, "work.conflict"]),
    ConflictA = filename:join([Dir, "work." ++ hexname("a")]),
    ConflictB = filename:join([Dir, "work." ++ hexname("b")]),
    ConflictC = filename:join([Dir, "work." ++ hexname("c")]),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    %% Create the remote files to merge
    ok = file:write_file(TmpFile, <<"b">>),
    ok = file:write_file(TmpFileUp, <<"c">>),
    %% cheating with internals
    {_, IdB} = revault_id:fork(revault_id:new()),
    {_, VsnB} = itc:explode(itc:event(itc:rebuild(IdB, undefined))),
    {_, VsnC} = itc:explode(itc:event(itc:rebuild(IdB, VsnB))),
    ok = revault_dirmon_tracker:conflict(Name, WorkFile, TmpFile, {VsnC, hash(<<"b">>)}),
    ?assertMatch({ok, _}, file:read_file(ConflictMarker)),
    ?assertMatch({error, enoent}, file:read_file(ConflictA)), % created on opposed end sync
    ?assertMatch({ok, _}, file:read_file(ConflictB)),
    %% Using an update with an older version is ignored
    ok = revault_dirmon_tracker:update_file(Name, WorkFile, TmpFileUp, {VsnB, hash(<<"c">>)}),
    ?assertMatch({ok, _}, file:read_file(ConflictMarker)),
    ?assertMatch({error, enoent}, file:read_file(ConflictA)), % created on opposed end sync
    ?assertMatch({ok, _}, file:read_file(ConflictB)),
    ?assertEqual({error, enoent}, file:read_file(ConflictC)),
    ok.

delete_file() ->
    [{doc, "A delete coming from another server needs to be marked in a way "
           "that is aware of the remote version, and not just of the file "
           "getting modified on disk. "
           "This can be handled by asking the tracker to directly remove "
           "the file from the tracked directory while bumping its version "
           "and ensuring that there is no clash with the scanner."}].
delete_file(Config) ->
    Name = ?config(name, Config),
    Dir = ?config(files_dir, Config),
    WorkFile = filename:join([Dir, "work"]),
    ok = file:write_file(WorkFile, <<"a">>),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    #{WorkFile := {VsnA, HashA}} = revault_dirmon_tracker:files(Name),
    ?assertEqual(HashA, hash(<<"a">>)),
    %% cheating with internals
    {_, IdB} = revault_id:fork(revault_id:new()),
    {_, VsnB} = itc:explode(itc:event(itc:rebuild(IdB, VsnA))),
    ok = revault_dirmon_tracker:delete_file(Name, WorkFile, {VsnB, deleted}),
    ?assertEqual({error, enoent}, file:read_file(WorkFile)),
    %% Check that changes in version are picked up properly
    ?assertEqual({VsnB, deleted}, revault_dirmon_tracker:file(Name, WorkFile)),
    %% Check that the change isn't picked more than once
    ok = revault_dirmon_event:force_scan(Name, 5000),
    ?assertEqual({VsnB, deleted}, revault_dirmon_tracker:file(Name, WorkFile)),
    ok.

delete_new() ->
    [{doc, "A deleted file coming from another server that does not exist locally "
           "is merged in a way that does not re-stamp the file to avoid "
           "the scanner re-detecting it and amplifying re-syncs with "
           "other peers."}].
delete_new(Config) ->
    Name = ?config(name, Config),
    Dir = ?config(files_dir, Config),
    WorkFile = filename:join([Dir, "work"]),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    %% cheating with internals
    {_, IdB} = revault_id:fork(revault_id:new()),
    {_, VsnB} = itc:explode(itc:event(itc:rebuild(IdB, undefined))),
    ok = revault_dirmon_tracker:delete_file(Name, WorkFile, {VsnB, deleted}),
    ?assertEqual({error, enoent}, file:read_file(WorkFile)),
    %% Check that changes in version are picked up properly
    {VsnB, deleted} = revault_dirmon_tracker:file(Name, WorkFile),
    %% Check that the change isn't picked more than once
    ok = revault_dirmon_event:force_scan(Name, 5000),
    ?assertEqual({VsnB, deleted}, revault_dirmon_tracker:file(Name, WorkFile)),
    ok.

delete_older() ->
    [{doc, "Deleting a newer file ignores any changes since the newer file wins."}].
delete_older(Config) ->
    Name = ?config(name, Config),
    Dir = ?config(files_dir, Config),
    WorkFile = filename:join([Dir, "work"]),
    ok = file:write_file(WorkFile, <<"a">>),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    #{WorkFile := {VsnA, HashA}} = revault_dirmon_tracker:files(Name),
    ?assertEqual(HashA, hash(<<"a">>)),
    ok = file:write_file(WorkFile, <<"b">>),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    #{WorkFile := {VsnB, HashB}} = revault_dirmon_tracker:files(Name),
    ?assertEqual(HashB, hash(<<"b">>)),
    %% merge and see it ignored
    ok = revault_dirmon_tracker:delete_file(Name, WorkFile, {VsnA, deleted}),
    ?assertEqual({ok, <<"b">>}, file:read_file(WorkFile)),
    %% Check that changes in version are picked up properly
    ?assertEqual({VsnB, HashB}, revault_dirmon_tracker:file(Name, WorkFile)),
    ok.

delete_conflict() ->
    [{doc, "Syncing a disjoint delete into a conflict results in the "
           "conflict being unchanged since the deletion does nothing."}].
delete_conflict(Config) ->
    Name = ?config(name, Config),
    Dir = ?config(files_dir, Config),
    TmpFile = filename:join([?config(tmp_dir, Config), "work"]),
    WorkFile = filename:join([Dir, "work"]),
    ConflictMarker = filename:join([Dir, "work.conflict"]),
    ConflictA = filename:join([Dir, "work." ++ hexname("a")]),
    ConflictB = filename:join([Dir, "work." ++ hexname("b")]),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    %% Create the remote files to merge
    ok = file:write_file(TmpFile, <<"b">>),
    %% cheating with internals
    {IdA, IdB} = revault_id:fork(revault_id:new()),
    {_, IdC} = revault_id:fork(IdA),
    {_, VsnB} = itc:explode(itc:event(itc:rebuild(IdB, undefined))),
    {_, VsnC} = itc:explode(itc:event(itc:rebuild(IdC, undefined))),
    ok = revault_dirmon_tracker:conflict(Name, WorkFile, TmpFile, {VsnB, hash(<<"b">>)}),
    ?assertMatch({ok, _}, file:read_file(ConflictMarker)),
    ?assertMatch({error, enoent}, file:read_file(ConflictA)), % created on opposed end sync
    ?assertMatch({ok, _}, file:read_file(ConflictB)),
    %% Using an update with a newer version resolves the conflict and cleares files
    ok = revault_dirmon_tracker:delete_file(Name, WorkFile, {VsnC, deleted}),
    ?assertMatch({ok, _}, file:read_file(ConflictMarker)),
    ?assertMatch({error, enoent}, file:read_file(ConflictA)), % created on opposed end sync
    ?assertMatch({ok, _}, file:read_file(ConflictB)),
    ok.

delete_conflict_resolve() ->
    [{doc, "Syncing a recent delete into a conflict results in the "
           "conflict resolving. Conflicting files are dropped as well."}].
delete_conflict_resolve(Config) ->
    Name = ?config(name, Config),
    Dir = ?config(files_dir, Config),
    TmpFile = filename:join([?config(tmp_dir, Config), "work"]),
    WorkFile = filename:join([Dir, "work"]),
    ConflictMarker = filename:join([Dir, "work.conflict"]),
    ConflictA = filename:join([Dir, "work." ++ hexname("a")]),
    ConflictB = filename:join([Dir, "work." ++ hexname("b")]),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    %% Create the remote files to merge
    ok = file:write_file(TmpFile, <<"b">>),
    %% cheating with internals
    {_, IdB} = revault_id:fork(revault_id:new()),
    {_, VsnB} = itc:explode(itc:event(itc:rebuild(IdB, undefined))),
    {_, VsnC} = itc:explode(itc:event(itc:rebuild(IdB, VsnB))),
    ok = revault_dirmon_tracker:conflict(Name, WorkFile, TmpFile, {VsnB, hash(<<"b">>)}),
    ?assertMatch({ok, _}, file:read_file(ConflictMarker)),
    ?assertMatch({error, enoent}, file:read_file(ConflictA)), % created on opposed end sync
    ?assertMatch({ok, _}, file:read_file(ConflictB)),
    %% Using an update with a newer version resolves the conflict and cleares files
    ok = revault_dirmon_tracker:delete_file(Name, WorkFile, {VsnC, deleted}),
    ?assertEqual({VsnC, deleted}, revault_dirmon_tracker:file(Name, WorkFile)),
    ?assertEqual({error, enoent}, file:read_file(ConflictMarker)),
    ?assertEqual({error, enoent}, file:read_file(ConflictB)),
    ?assertEqual({error, enoent}, file:read_file(WorkFile)),
    %% Check that the change isn't picked more than once
    ok = revault_dirmon_event:force_scan(Name, 5000),
    ?assertEqual({VsnC, deleted}, revault_dirmon_tracker:file(Name, WorkFile)),
    ok.

delete_conflict_older() ->
    [{doc, "Syncing an old delete into a newer conflict results in the "
           "delete being ignored"}].
delete_conflict_older(Config) ->
    Name = ?config(name, Config),
    Dir = ?config(files_dir, Config),
    TmpFile = filename:join([?config(tmp_dir, Config), "work"]),
    WorkFile = filename:join([Dir, "work"]),
    ConflictMarker = filename:join([Dir, "work.conflict"]),
    ConflictA = filename:join([Dir, "work." ++ hexname("a")]),
    ConflictB = filename:join([Dir, "work." ++ hexname("b")]),
    ok = revault_dirmon_event:force_scan(Name, 5000),
    %% Create the remote files to merge
    ok = file:write_file(TmpFile, <<"b">>),
    %% cheating with internals
    {_, IdB} = revault_id:fork(revault_id:new()),
    {_, VsnB} = itc:explode(itc:event(itc:rebuild(IdB, undefined))),
    {_, VsnC} = itc:explode(itc:event(itc:rebuild(IdB, VsnB))),
    ok = revault_dirmon_tracker:conflict(Name, WorkFile, TmpFile, {VsnC, hash(<<"b">>)}),
    ?assertMatch({ok, _}, file:read_file(ConflictMarker)),
    ?assertMatch({error, enoent}, file:read_file(ConflictA)), % created on opposed end sync
    ?assertMatch({ok, _}, file:read_file(ConflictB)),
    %% Using an update with an older version is ignored
    ok = revault_dirmon_tracker:delete_file(Name, WorkFile, {VsnB, deleted}),
    ?assertMatch({ok, _}, file:read_file(ConflictMarker)),
    ?assertMatch({error, enoent}, file:read_file(ConflictA)), % created on opposed end sync
    ?assertMatch({ok, _}, file:read_file(ConflictB)),
    ok.

%%%%%%%%%%%%%%%
%%% HELPERS %%%
%%%%%%%%%%%%%%%
hash(Bin) -> crypto:hash(sha256, Bin).
hex(Bin) -> binary:encode_hex(hash(Bin)).
hexname(Bin) -> unicode:characters_to_list(string:slice(hex(Bin), 0, 8)).
