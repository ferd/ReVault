-module(revault_sync_fsm_SUITE).
-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").
-compile(export_all).

all() ->
    [start_hierarchy, client_id, client_no_server, client_uninit_server,
     fork_server_save, basic_sync].

init_per_testcase(Case, Config) when Case =:= start_hierarchy;
                                     Case =:= client_no_server ->
    {ok, Apps} = application:ensure_all_started(gproc),
    Priv = ?config(priv_dir, Config),
    DbDir = filename:join([Priv, "db"]),
    Path = filename:join([Priv, "data"]),
    %% ensure directories exist
    filelib:ensure_dir(filename:join([DbDir, "fakefile"])),
    filelib:ensure_dir(filename:join([Path, "fakefile"])),
    Name = atom_to_list(?MODULE) ++ "_" ++ atom_to_list(Case),
    Interval = 100000000, % don't scan yet
    [{db_dir, DbDir},
     {path, Path},
     {name, Name},
     {interval, Interval},
     {apps, Apps} | Config];
init_per_testcase(client_uninit_server, Config) ->
    init_per_testcase(client_deferred_uninit_server, [{init_server, false} | Config]);
init_per_testcase(Case, Config) ->
    {ok, Apps} = application:ensure_all_started(gproc),
    Priv = ?config(priv_dir, Config),
    DbDir = filename:join([Priv, "db"]),
    Path = filename:join([Priv, "data", "client"]),
    ServerPath = filename:join([Priv, "data", "server"]),
    %% ensure directories exist
    filelib:ensure_dir(filename:join([DbDir, "fakefile"])),
    filelib:ensure_dir(filename:join([Path, "fakefile"])),
    filelib:ensure_dir(filename:join([ServerPath, "fakefile"])),
    Name = atom_to_list(?MODULE) ++ "_" ++ atom_to_list(Case),
    ServerName = atom_to_list(?MODULE) ++ "_" ++ atom_to_list(Case) ++ "_server",
    Interval = 100000000, % don't scan yet
    %% Starting the hierarchy
    {ok, Sup} = revault_sup:start_link(),
    {ok, Fsm} = revault_fsm_sup:start_fsm(DbDir, ServerName, ServerPath, Interval),
    ok = revault_sync_fsm:server(ServerName),
    %% set up ID if not done, and if allowed
    ?config(init_server, Config) =/= false andalso revault_sync_fsm:id(ServerName),
    [{db_dir, DbDir},
     {path, Path},
     {server_path, ServerPath},
     {name, Name},
     {interval, Interval},
     {sup, Sup}, {fsm, Fsm},
     {server, ServerName},
     {apps, Apps} | Config].

end_per_testcase(start_hierarchy, Config) ->
    [application:stop(App) || App <- ?config(apps, Config)],
    Config;
end_per_testcase(client_no_server, Config) ->
    [application:stop(App) || App <- ?config(apps, Config)],
    Config;
end_per_testcase(_, Config) ->
    unlink(?config(fsm, Config)),
    unlink(?config(sup, Config)),
    gen_server:stop(?config(sup, Config)),
    [application:stop(App) || App <- ?config(apps, Config)],
    Config.

start_hierarchy() ->
    [{doc, "Starting the sync FSM starts the whole overall mechanism."}].
start_hierarchy(Config) ->
    Name = ?config(name, Config),
    {ok, Sup} = revault_sup:start_link(),
    {ok, Fsm} = revault_fsm_sup:start_fsm(
        ?config(db_dir, Config),
        Name,
        ?config(path, Config),
        ?config(interval, Config)
    ),
    %% The FSM is alive and we know it, declare it a server so it runs solo
    ok = revault_sync_fsm:server(Name),
    %% Can't force to switch to client mode now!
    ?assertEqual({error, busy}, revault_sync_fsm:client(Name)),
    %% As a server it bootstrapped its own ID
    ?assertNotEqual(undefined, revault_sync_fsm:id(Name)),
    %% The supervision structure should have been started as part of the setup
    ?assert(is_pid(gproc:where({n, l, {revault_sync_fsm, Name}}))),
    ?assert(is_pid(gproc:where({n, l, {revault_tracker_sup, Name}}))),
    ?assert(is_pid(gproc:where({n, l, {revault_dirmon_tracker, Name}}))),
    ?assert(is_pid(gproc:where({n, l, {revault_dirmon_event, Name}}))),
    %% Now shut down the supervision structure
    unlink(Fsm),
    unlink(Sup),
    gen_server:stop(Sup),
    ?assertEqual(undefined, gproc:where({n, l, {revault_sync_fsm, Name}})),
    ?assertEqual(undefined, gproc:where({n, l, {revault_tracker_sup, Name}})),
    ?assertEqual(undefined, gproc:where({n, l, {revault_dirmon_tracker, Name}})),
    ?assertEqual(undefined, gproc:where({n, l, {revault_dirmon_event, Name}})),
    ok.

client_id() ->
    [{doc, "Starting a client means it can get its ID from an online server."}].
client_id(Config) ->
    Name = ?config(name, Config),
    Remote = {Server=?config(server, Config), node()}, % using distributed erlang
    {ok, ServId1} = revault_sync_fsm:id(Server),
    {ok, _} = revault_fsm_sup:start_fsm(
        ?config(db_dir, Config),
        Name,
        ?config(path, Config),
        ?config(interval, Config)
    ),
    %% How to specify what sort of client we are? to which server?
    ok = revault_sync_fsm:client(Name),
    ?assertEqual({error, busy}, revault_sync_fsm:client(Name)),
    ?assertEqual({error, busy}, revault_sync_fsm:server(Name)),
    ?assertEqual(undefined, revault_sync_fsm:id(Name)),
    {ok, ClientId} = revault_sync_fsm:id(Name, Remote),
    {ok, ServId2} = revault_sync_fsm:id(Server),
    ?assertNotEqual(undefined, ClientId),
    ?assertNotEqual(ServId1, ServId2),
    ?assertNotEqual(ServId2, ClientId),
    ?assertNotEqual(ServId1, ClientId),
    %% Now shut down the client and restart it and make sure it works
    gen_server:stop(revault_fsm_sup, normal, 5000),
    {ok, Pid} = revault_sync_fsm:start_link(
        ?config(db_dir, Config),
        Name,
        ?config(path, Config),
        ?config(interval, Config)
    ),
    ok = revault_sync_fsm:client(Name),
    ?assertEqual({ok, ClientId}, revault_sync_fsm:id(Name)),
    unlink(Pid),
    gen_statem:stop(Pid, normal, 5000),
    ok.

client_no_server() ->
    [{doc, "A server not being available makes the ID fetching error out"}].
client_no_server(Config) ->
    Name = ?config(name, Config),
    Remote = {"does not exist", node()}, % using distributed erlang
    {ok, Sup} = revault_sup:start_link(),
    {ok, _} = revault_fsm_sup:start_fsm(
        ?config(db_dir, Config),
        Name,
        ?config(path, Config),
        ?config(interval, Config)
    ),
    %% How to specify what sort of client we are? to which server?
    ok = revault_sync_fsm:client(Name),
    ?assertEqual({error, busy}, revault_sync_fsm:client(Name)),
    ?assertEqual({error, busy}, revault_sync_fsm:server(Name)),
    ?assertEqual(undefined, revault_sync_fsm:id(Name)),
    ?assertEqual({error, sync_failed}, revault_sync_fsm:id(Name, Remote)),
    unlink(Sup),
    gen_server:stop(Sup),
    ok.

client_uninit_server() ->
    [{doc, "If the server is started but not initialized, we fail to set "
           "a client id"}].
client_uninit_server(Config) ->
    Name = ?config(name, Config),
    Remote = {?config(server, Config), node()}, % using distributed erlang
    {ok, _} = revault_fsm_sup:start_fsm(
        ?config(db_dir, Config),
        Name,
        ?config(path, Config),
        ?config(interval, Config)
    ),
    %% How to specify what sort of client we are? to which server?
    ok = revault_sync_fsm:client(Name),
    ?assertEqual(undefined, revault_sync_fsm:id(Name)),
    ?assertEqual({error, sync_failed}, revault_sync_fsm:id(Name, Remote)),
    ok.

fork_server_save() ->
    [{doc, "A server forking its ID saves it to disk and its workers "
           "have it live-updated."}].
fork_server_save(Config) ->
    Name = ?config(name, Config),
    Remote = {Server=?config(server, Config), node()}, % using distributed erlang
    {ok, ServId1} = revault_sync_fsm:id(Server),
    {ok, _} = revault_fsm_sup:start_fsm(
        ?config(db_dir, Config),
        Name,
        ?config(path, Config),
        ?config(interval, Config)
    ),
    ok = revault_sync_fsm:client(Name),
    {ok, _ClientId} = revault_sync_fsm:id(Name, Remote),
    {ok, ServId2} = revault_sync_fsm:id(Server),
    ?assertNotEqual(ServId2, ServId1),
    %% Check ID on disk
    IDFile = filename:join([?config(db_dir, Config), Server, "id"]),
    {ok, BinId} = file:read_file(IDFile),
    ?assertEqual(ServId2, binary_to_term(BinId)),
    %% Check worker ID, peek into internal state even if brittle.
    State = sys:get_state({via, gproc, {n, l, {revault_dirmon_tracker, Server}}}),
    ?assertEqual(ServId2, element(4, State)),
    ok.

basic_sync() ->
    [{doc, "Basic file synchronization works"}].
basic_sync(Config) ->
    Client = ?config(name, Config),
    Remote = {Server=?config(server, Config), node()}, % using distributed erlang
    ClientPath = ?config(path, Config),
    ServerPath = ?config(server_path, Config),
    {ok, ServId1} = revault_sync_fsm:id(Server),
    {ok, _} = revault_fsm_sup:start_fsm(
        ?config(db_dir, Config),
        Client,
        ClientPath,
        ?config(interval, Config)
    ),
    ok = revault_sync_fsm:client(Client),
    {ok, _ClientId} = revault_sync_fsm:id(Client, Remote),
    %% Write files
    ok = file:write_file(filename:join([ClientPath, "client-only"]), "c1"),
    ok = file:write_file(filename:join([ServerPath, "server-only"]), "s1"),
    ok = file:write_file(filename:join([ServerPath, "shared"]), "sh1"),
    ok = file:write_file(filename:join([ClientPath, "shared"]), "sh2"),
    %% Track em
    ok = revault_dirmon_event:force_scan(Client, 5000),
    ok = revault_dirmon_event:force_scan(Server, 5000),
    %% Sync em
    ok = revault_sync_fsm:sync(Client, Remote),
    %% See the result
    %% 1. all unmodified files are left in place
    ?assertEqual({ok, <<"c1">>}, file:read_file(filename:join([ClientPath, "client-only"]))),
    ?assertEqual({ok, <<"s1">>}, file:read_file(filename:join([ServerPath, "server-only"]))),
    %% 2. conflicting files are marked, with the working files left intact
    ?assertEqual({ok, <<"sh1">>}, file:read_file(filename:join([ServerPath, "shared"]))),
    ?assertEqual({ok, <<"sh2">>}, file:read_file(filename:join([ClientPath, "shared"]))),
    ?assertEqual(
        {ok, <<"1C56416E18E2FE12E55CB8DE8AB3BB54DEDEC94C942520403CCD2E8DCA7BF8D5\n"
               "D6BE7FB89A392FE342033E3ECCFF9CADFC4A58A19316E162E079D662762CE8B8">>},
        file:read_file(filename:join([ServerPath, "shared.conflict"]))
    ),
    ?assertEqual(
        {ok, <<"1C56416E18E2FE12E55CB8DE8AB3BB54DEDEC94C942520403CCD2E8DCA7BF8D5\n"
               "D6BE7FB89A392FE342033E3ECCFF9CADFC4A58A19316E162E079D662762CE8B8">>},
        file:read_file(filename:join([ClientPath, "shared.conflict"]))
    ),
    ?assertEqual({ok, <<"sh1">>}, file:read_file(filename:join([ServerPath, "shared.D6BE7FB8"]))),
    ?assertEqual({ok, <<"sh2">>}, file:read_file(filename:join([ServerPath, "shared.1C56416E"]))),
    ?assertEqual({ok, <<"sh1">>}, file:read_file(filename:join([ClientPath, "shared.D6BE7FB8"]))),
    ?assertEqual({ok, <<"sh2">>}, file:read_file(filename:join([ClientPath, "shared.1C56416E"]))),
    %% The working file can be edited however.
    %% Resolve em and add a file
    ok = file:delete(filename:join([ClientPath, "shared.1C56416E"])),
    ok = file:move(filename:join([ClientPath, "shared.D6BE7FB8"]),
                   filename:join([ClientPath, "shared"])),
    ok = file:delete(filename:join([ClientPath, "shared.conflict"])),
    ok = file:write_file(filename:join([ClientPath, "client-2"]), "c2"),
    %% Sync again, but only track on the client side
    ok = revault_dirmon_event:force_scan(Client, 5000),
    ok = revault_sync_fsm:sync(Client, Remote),
    %% TODO: check with a 3rd party for extra transitive conflicts
    %% the following should be moved to a lower-level test:
    %% Check again
    ?assertEqual({ok, <<"c1">>}, file:read_file(filename:join([ClientPath, "client-only"]))),
    ?assertEqual({ok, <<"c2">>}, file:read_file(filename:join([ClientPath, "client-2"]))),
    ?assertEqual({ok, <<"s1">>}, file:read_file(filename:join([ServerPath, "server-only"]))),
    ?assertEqual({ok, <<"sh1">>}, file:read_file(filename:join([ServerPath, "shared"]))),
    ?assertEqual({ok, <<"sh1">>}, file:read_file(filename:join([ClientPath, "shared"]))),
    ?assertEqual({ok, <<"c2">>}, file:read_file(filename:join([ServerPath, "client-2"]))),
    ?assertEqual({error, enoent}, file:read_file(filename:join([ServerPath, "shared.conflict"]))),
    ?assertEqual({error, enoent}, file:read_file(filename:join([ServerPath, "shared.D6BE7FB8"]))),
    ?assertEqual({error, enoent}, file:read_file(filename:join([ServerPath, "shared.1C56416E"]))),
    ?assertEqual({error, enoent}, file:read_file(filename:join([ClientPath, "shared.conflict"]))),
    ?assertEqual({error, enoent}, file:read_file(filename:join([ClientPath, "shared.D6BE7FB8"]))),
    ?assertEqual({error, enoent}, file:read_file(filename:join([ClientPath, "shared.1C56416E"]))),
    ok.

%% TODO: test overwrite sync
