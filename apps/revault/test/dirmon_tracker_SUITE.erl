-module(dirmon_tracker_SUITE).
-compile(export_all).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [update_file,
     conflict_creation,
     {group, conflict_resolution}].

groups() ->
    [{conflict_resolution, [], [
        conflict_resolution_orderly,
        conflict_resolution_orderly_deleted,
        conflict_resolution_marker_first,
        conflict_resolution_drop_conflict
     ]}
    ].


    %% TODO: updating a file that doesn't exist won't re-stamp
    %% TODO: updating a file from an older file ignores the file change
    %% TODO: updating a file as a deletion works
    %% TODO: do the thing where you delete the conflict file first and then drop the hashes
    %%       although that wouldn't be needed.
    %% TODO: do the thing where a conflict candidate is dropped and make sure it's removed
    %%       from the tracked file
    %% TODO: weird ass things like moving conflicting files around
    %% TODO: updating a file into a conflict when the new file is newer is a resolution
    %% TODO: updating a file into a conflict when the new file is older is ignored
    %% TODO: updating a file into a conflict when the new file clashes adds to the conflict

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


%%%%%%%%%%%%%%%
%%% HELPERS %%%
%%%%%%%%%%%%%%%
hash(Bin) -> crypto:hash(sha256, Bin).
hex(Bin) -> binary:encode_hex(hash(Bin)).
hexname(Bin) -> unicode:characters_to_list(string:slice(hex(Bin), 0, 8)).
