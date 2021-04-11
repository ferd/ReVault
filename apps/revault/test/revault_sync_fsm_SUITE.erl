-module(revault_sync_fsm_SUITE).
-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").
-compile(export_all).

all() ->
    [start_hierarchy, client_id, client_no_server, client_uninit_server].

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
    %% TODO: Check remote server that isn't initialized
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
