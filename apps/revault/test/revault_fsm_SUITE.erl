-module(revault_fsm_SUITE).
-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").
-compile(export_all).

-define(UUID_RECORD_POS, 4).

all() ->
    [start_hierarchy,
     {group, disterl},
     {group, tcp},
     {group, tls}].

groups() ->
    [{disterl, [], [{group, syncs}]},
     {tcp, [], [{group, syncs}]},
     {tls, [], [{group, syncs}]},
     {syncs, [], [client_id, client_no_server,
                  fork_server_save, basic_sync, too_many_clients,
                  overwrite_sync_clash, conflict_sync,
                  prevent_server_clash]}].

init_per_group(tcp, Config) ->
    [{callback, fun(Name) ->
        revault_tcp:callback({Name, <<"test">>, #{
            <<"peers">> => #{
                <<"test">> => #{
                    <<"sync">> => [<<"test">>],
                    <<"url">> => <<"localhost:8888">>,
                    <<"auth">> => #{<<"type">> => <<"none">>}
                }
            },
            <<"server">> => #{<<"auth">> => #{
                <<"none">> => #{
                    <<"status">> => enabled,
                    <<"port">> => 8888,
                    <<"sync">> => [<<"test">>],
                    <<"mode">> => read_write
                }
            }}
        }})
     end},
     {nohost_callback, fun(Name) ->
        revault_tcp:callback({Name, <<"test">>, #{
            <<"peers">> => #{
                <<"test">> => #{
                    <<"sync">> => [<<"test">>],
                    <<"url">> => <<"localhost:33333">>,
                    <<"auth">> => #{<<"type">> => <<"none">>}
                }
            },
            <<"server">> => #{}
        }})
    end},
    {peer, fun(_Name) -> <<"test">> end} | Config];
init_per_group(disterl, Config) ->
    [{callback, fun revault_disterl:callback/1},
     {nohost_callback, fun revault_disterl:callback/1},
     {peer, fun(Name) -> {Name, node()} end} | Config];
init_per_group(tls, Config) ->
    CertDir = ?config(data_dir, Config),
    [{callback, fun(Name) ->
        revault_tls:callback({Name, <<"test">>, #{
            <<"peers">> => #{
                <<"test">> => #{
                    <<"sync">> => [<<"test">>],
                    <<"url">> => <<"localhost:8889">>,
                    <<"auth">> => #{
                        <<"type">> => <<"tls">>,
                        <<"certfile">> => filename:join(CertDir, "key_a.crt"),
                        <<"keyfile">> => filename:join(CertDir, "key_a.key"),
                        <<"peer_certfile">> => filename:join(CertDir, "key_b.crt")
                    }
                }
            },
            <<"server">> => #{<<"auth">> => #{
                <<"tls">> => #{
                    <<"status">> => enabled,
                    <<"port">> => 8889,
                    <<"certfile">> => filename:join(CertDir, "key_b.crt"),
                    <<"keyfile">> => filename:join(CertDir, "key_b.key"),
                    <<"authorized">> => #{
                        <<"test">> => #{
                            <<"certfile">> => filename:join(CertDir, "key_a.crt"),
                            <<"sync">> => [<<"test">>],
                            <<"mode">> => read_write
                        }
                    }
                }
            }}
        }})
    end},
    {nohost_callback, fun(Name) ->
        revault_tls:callback({Name, <<"test">>, #{
            <<"peers">> => #{
                <<"test">> => #{
                    <<"sync">> => [<<"test">>],
                    <<"url">> => <<"localhost:33333">>,
                    <<"auth">> => #{
                        <<"type">> => <<"tls">>,
                        <<"certfile">> => filename:join(CertDir, "key_a.crt"),
                    <<"keyfile">> => filename:join(CertDir, "key_a.key"),
                    <<"peer_certfile">> => filename:join(CertDir, "key_b.crt")
                    }
                }
            },
            <<"server">> => #{}
        }})
    end},
    {peer, fun(_Name) -> <<"test">> end} | Config];
init_per_group(_, Config) ->
    Config.

end_per_group(_Group, Config) ->
    Config.

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
init_per_testcase(Case, Config) ->
    {ok, Apps} = application:ensure_all_started(gproc),
    Priv = ?config(priv_dir, Config),
    CbInit = ?config(callback, Config),
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
    {ok, Fsm} = revault_fsm_sup:start_fsm(DbDir, ServerName, ServerPath, Interval,
                                          CbInit(ServerName)),
    ok = revault_fsm:server(ServerName), %% sets up the ID and parks itself in server state.
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
    wait_dead([revault_sup, revault_protocols_sup, revault_trackers_sup]),
    Config.

start_hierarchy() ->
    [{doc, "Starting the sync FSM starts the whole overall mechanism."},
     {timetrap, timer:seconds(5)}].
start_hierarchy(Config) ->
    Name = ?config(name, Config),
    {ok, Sup} = revault_sup:start_link(),
    {ok, Fsm} = revault_fsm_sup:start_fsm(
        ?config(db_dir, Config),
        Name,
        ?config(path, Config),
        ?config(interval, Config)
    ),
    %% The FSM is alive and we know it, declare it a server so it self-initializes
    ok = revault_fsm:server(Name),
    %% As a server it bootstrapped its own ID
    ?assertNotEqual(undefined, revault_fsm:id(Name)),
    %% Can't force to switch to client mode now!
    ?assertEqual({error, busy}, revault_fsm:client(Name)),
    %% The supervision structure should have been started as part of the setup
    ?assert(is_pid(gproc:where({n, l, {revault_fsm, Name}}))),
    ?assert(is_pid(gproc:where({n, l, {revault_tracker_sup, Name}}))),
    ?assert(is_pid(gproc:where({n, l, {revault_dirmon_tracker, Name}}))),
    ?assert(is_pid(gproc:where({n, l, {revault_dirmon_event, Name}}))),
    %% Now shut down the supervision structure
    unlink(Fsm),
    unlink(Sup),
    gen_server:stop(Sup),
    ?assertEqual(undefined, gproc:where({n, l, {revault_fsm, Name}})),
    ?assertEqual(undefined, gproc:where({n, l, {revault_tracker_sup, Name}})),
    ?assertEqual(undefined, gproc:where({n, l, {revault_dirmon_tracker, Name}})),
    ?assertEqual(undefined, gproc:where({n, l, {revault_dirmon_event, Name}})),
    ok.

client_id() ->
    [{doc, "Starting a client means it can get its ID from an online server."},
     {timetrap, timer:seconds(5)}].
client_id(Config) ->
    Name = ?config(name, Config),
    Server=?config(server, Config),
    Remote = (?config(peer, Config))(Server),
    {ok, ServId1} = revault_fsm:id(Server),
    {ok, _} = revault_fsm_sup:start_fsm(
        ?config(db_dir, Config),
        Name,
        ?config(path, Config),
        ?config(interval, Config),
        (?config(callback, Config))(Name)
    ),
    %% How to specify what sort of client we are? to which server?
    ok = revault_fsm:client(Name),
    ?assertEqual({error, busy}, revault_fsm:client(Name)),
    ?assertEqual({error, busy}, revault_fsm:server(Name)),
    ?assertEqual(undefined, revault_fsm:id(Name)),
    {ok, ClientId} = revault_fsm:id(Name, Remote),
    {ok, ServId2} = revault_fsm:id(Server),
    ?assertNotEqual(undefined, ClientId),
    ?assertNotEqual(ServId1, ServId2),
    ?assertNotEqual(ServId2, ClientId),
    ?assertNotEqual(ServId1, ClientId),
    %% Now shut down the client and restart it and make sure it works
    gen_server:stop(revault_fsm_sup, normal, 5000),
    {ok, Pid} = revault_fsm:start_link(
        ?config(db_dir, Config),
        Name,
        ?config(path, Config),
        ?config(interval, Config)
    ),
    %% See that we have a tracker going even without defining a role
    wait_alive([{n,l, {revault_dirmon_tracker, Name}}]),
    %% Define a role
    ok = revault_fsm:client(Name),
    ?assertEqual({ok, ClientId}, revault_fsm:id(Name)),
    unlink(Pid),
    gen_statem:stop(Pid, normal, 5000),
    ok.

client_no_server() ->
    [{doc, "A server not being available makes the ID fetching error out"},
     {timetrap, timer:seconds(5)}].
client_no_server(Config) ->
    Name = ?config(name, Config),
    Remote = (?config(peer, Config))(<<"does not exist">>),
    {ok, Sup} = revault_sup:start_link(),
    {ok, _} = revault_fsm_sup:start_fsm(
        ?config(db_dir, Config),
        Name,
        ?config(path, Config),
        ?config(interval, Config),
        (?config(nohost_callback, Config))(Name)
    ),
    ?assertEqual(undefined, revault_fsm:id(Name)),
    %% How to specify what sort of client we are? to which server?
    ok = revault_fsm:client(Name),
    ?assertEqual({error, busy}, revault_fsm:client(Name)),
    ?assertEqual({error, busy}, revault_fsm:server(Name)),
    ?assertEqual(undefined, revault_fsm:id(Name)),
    ?assertEqual({error, sync_failed}, revault_fsm:id(Name, Remote)),
    unlink(Sup),
    gen_server:stop(Sup),
    ok.

fork_server_save() ->
    [{doc, "A server forking its ID saves it to disk and its workers "
           "have it live-updated."},
     {timetrap, timer:seconds(5)}].
fork_server_save(Config) ->
    Name = ?config(name, Config),
    Server=?config(server, Config),
    Remote = (?config(peer, Config))(Server),
    {ok, ServId1} = revault_fsm:id(Server),
    {ok, _} = revault_fsm_sup:start_fsm(
        ?config(db_dir, Config),
        Name,
        ?config(path, Config),
        ?config(interval, Config),
        (?config(callback, Config))(Name)
    ),
    ok = revault_fsm:client(Name),
    {ok, _ClientId} = revault_fsm:id(Name, Remote),
    {ok, ServId2} = revault_fsm:id(Server),
    ?assertNotEqual(ServId2, ServId1),
    %% Check ID on disk
    IDFile = filename:join([?config(db_dir, Config), Server, "id"]),
    {ok, BinId} = file:read_file(IDFile),
    ?assertEqual(ServId2, binary_to_term(BinId)),
    %% Check worker ID, peek into internal state even if brittle.
    State = sys:get_state({via, gproc, {n, l, {revault_dirmon_tracker, Server}}}),
    ?assertEqual(ServId2, element(5, State)),
    ok.

basic_sync() ->
    [{doc, "Basic file synchronization works"},
     {timetrap, timer:seconds(5)}].
basic_sync(Config) ->
    Client = ?config(name, Config),
    Server = ?config(server, Config),
    Remote = (?config(peer, Config))(Server),
    ClientPath = ?config(path, Config),
    ServerPath = ?config(server_path, Config),
    {ok, _ServId1} = revault_fsm:id(Server),
    {ok, _} = revault_fsm_sup:start_fsm(
        ?config(db_dir, Config),
        Client,
        ClientPath,
        ?config(interval, Config),
        (?config(callback, Config))(Client)
    ),
    ok = revault_fsm:client(Client),
    {ok, _ClientId} = revault_fsm:id(Client, Remote),
    %% now in initialized mode
    %% Write files
    ok = file:write_file(filename:join([ClientPath, "client-only"]), "c1"),
    ok = file:write_file(filename:join([ServerPath, "server-only"]), "s1"),
    ok = file:write_file(filename:join([ServerPath, "shared"]), "sh1"),
    ok = file:write_file(filename:join([ClientPath, "shared"]), "sh2"),
    %% Track em
    ok = revault_dirmon_event:force_scan(Client, 5000),
    ok = revault_dirmon_event:force_scan(Server, 5000),
    %% Sync em
    ok = revault_fsm:sync(Client, Remote),
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
    ct:pal("RACE_AREA"),
    %% POTENTIAL RACE CONDITION!
    %%   moving the shared.D6BE7FB8 and deleting shared.D6BE7FB8 and then
    %%   deleting shared.conflict can yield, upon a scan, a sequence where
    %%   the server itself recreates the shared.conflict file.
    %%   Conditionals in the code are assumed to cover this case.
    ok = file:delete(filename:join([ClientPath, "shared.1C56416E"])),
    ok = file:rename(filename:join([ClientPath, "shared.D6BE7FB8"]),
                     filename:join([ClientPath, "shared"])),
    ok = file:delete(filename:join([ClientPath, "shared.conflict"])),
    ok = file:write_file(filename:join([ClientPath, "client-2"]), "c2"),
    %% Sync again, but only track on the client side
    ok = revault_dirmon_event:force_scan(Client, 5000),
    %% TODO: should we go back to idle mode and re-force setting a client here?
    ct:pal("RE-SYNC"),
    ok = revault_fsm:sync(Client, Remote),
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

too_many_clients() ->
    [{doc, "Make sure that a given server does not get confused by connecting "
           "with too many clients at once."},
     {timetrap, timer:seconds(5)}].
too_many_clients(Config) ->
    Client = ?config(name, Config),
    Server=?config(server, Config),
    Remote = (?config(peer, Config))(Server),
    ClientPath = ?config(path, Config),
    {ok, _ServId1} = revault_fsm:id(Server),
    {ok, _} = revault_fsm_sup:start_fsm(
        ?config(db_dir, Config),
        Client,
        ClientPath,
        ?config(interval, Config),
        (?config(callback, Config))(Client)
    ),
    ok = revault_fsm:client(Client),
    {ok, _ClientId} = revault_fsm:id(Client, Remote),
    %% Now we can start another client, and it should fail trying to sync.
    Client2 = Client ++ "_2",
    Priv = ?config(priv_dir, Config),
    DbDir = filename:join([Priv, "db_2"]),
    Path = filename:join([Priv, "data", "client_2"]),
    filelib:ensure_dir(filename:join([DbDir, "fakefile"])),
    filelib:ensure_dir(filename:join([Path, "fakefile"])),
    {ok, _} = revault_fsm_sup:start_fsm(DbDir, Client2, Path, ?config(interval, Config),
                                        (?config(callback, Config))(Client2)),
    ok = revault_fsm:client(Client2),
    %% Since each sync calls for its own Remote, we can assume we can safely
    %% ask for an ID even if another remote is in place.
    ?assertMatch({ok, _}, revault_fsm:id(Client2, Remote)),
    %% We can get wedged halfway through another client's sync
    %% After the sync, we can finally work again.
    %% However, getting a client stuck demands going fast enough that the test
    %% would be brittle. We can cheat by making file access via data wrappers
    %% incredibly slow!
    try
        block(),
        meck:new(revault_data_wrapper, [passthrough]),
        meck:expect(revault_data_wrapper, send_file,
                    fun(A,B,C,D) -> block_loop(), meck:passthrough([A,B,C,D]) end),
        %% Write files, client-only so only the client blocks
        ok = file:write_file(filename:join([ClientPath, "client-only"]), "c1"),
        %% Track em
        ok = revault_dirmon_event:force_scan(Client, 5000),
        ok = revault_dirmon_event:force_scan(Server, 5000),
        %% Sync em
        P = self(),
        spawn_link(fun() -> P ! ok, revault_fsm:sync(Client, Remote), P ! ok end),
        receive
            ok -> timer:sleep(50) % give time to the async call above to start
        end,
        ?assertEqual({error, peer_busy}, revault_fsm:sync(Client2, Remote)),
        unblock(),
        %% wait for things to be done before unloading meck, or this causes crashes
        receive ok -> ok end
    after
        meck:unload(revault_data_wrapper)
    end,
    ?assertEqual(ok, revault_fsm:sync(Client2, Remote)),
    ok.

overwrite_sync_clash() ->
    [{doc, "A file being overwritten during a transfer doesn't end up "
           "corrupting it at the call-site. Aborting is accepted."},
     {timetrap, timer:seconds(5)}].
overwrite_sync_clash(Config) ->
    Client = ?config(name, Config),
    Server=?config(server, Config),
    Remote = (?config(peer, Config))(Server),
    ClientPath = ?config(path, Config),
    ServerPath = ?config(server_path, Config),
    {ok, _ServId1} = revault_fsm:id(Server),
    {ok, _} = revault_fsm_sup:start_fsm(
        ?config(db_dir, Config),
        Client,
        ClientPath,
        ?config(interval, Config),
        (?config(callback, Config))(Client)
    ),
    ok = revault_fsm:client(Client),
    {ok, _ClientId} = revault_fsm:id(Client, Remote),
    ok = file:write_file(filename:join([ServerPath, "shared"]), "sh1"),
    %% Getting a client racing demands going fast enough that the test
    %% would be brittle. We can cheat by making file access via data wrappers
    %% incredibly slow!
    try
        block(),
        meck:new(revault_data_wrapper, [passthrough]),
        meck:expect(revault_data_wrapper, send_file,
                    fun(A,B,C,D) -> block_loop(), meck:passthrough([A,B,C,D]) end),
        %% Track em
        ok = revault_dirmon_event:force_scan(Client, 5000),
        ok = revault_dirmon_event:force_scan(Server, 5000),
        %% Write files, client-only so only the server blocks, with the corrupted data
        ok = file:write_file(filename:join([ServerPath, "shared"]), "corrupted"),
        %% Sync em
        P = self(),
        spawn_link(fun() -> P ! ok, revault_fsm:sync(Client, Remote), P ! ok end),
        receive
            ok -> timer:sleep(50) % give time to the async call above to start
        end,
        unblock(),
        %% wait for things to be done before unloading meck, or this causes crashes
        receive ok -> ok end
    after
        meck:unload(revault_data_wrapper)
    end,
    ?assertNotEqual({ok, <<"corrupted">>},
                    file:read_file(filename:join([ClientPath, "shared"]))),
    ok.

conflict_sync() ->
    [{doc, "A conflict file can be sync'd to a third party"},
     {timetrap, timer:seconds(5)}].
conflict_sync(Config) ->
    Client = ?config(name, Config),
    Server=?config(server, Config),
    Remote = (?config(peer, Config))(Server),
    ClientPath = ?config(path, Config),
    ServerPath = ?config(server_path, Config),
    {ok, _ServId1} = revault_fsm:id(Server),
    {ok, _} = revault_fsm_sup:start_fsm(
        ?config(db_dir, Config),
        Client,
        ClientPath,
        ?config(interval, Config),
        (?config(callback, Config))(Client)
    ),
    ok = revault_fsm:client(Client),
    {ok, _ClientId} = revault_fsm:id(Client, Remote),
    %% Set up a second client; because of how config works in the test, it needs
    Client2 = Client ++ "_2",
    Priv = ?config(priv_dir, Config),
    DbDir2 = filename:join([Priv, "db_2"]),
    ClientPath2 = filename:join([Priv, "data", "client_2"]),
    filelib:ensure_dir(filename:join([DbDir2, "fakefile"])),
    filelib:ensure_dir(filename:join([ClientPath2, "fakefile"])),
    {ok, _} = revault_fsm_sup:start_fsm(DbDir2, Client2, ClientPath2, ?config(interval, Config),
                                        (?config(callback, Config))(Client2)),
    ok = revault_fsm:client(Client2),
    ?assertMatch({ok, _}, revault_fsm:id(Client2, Remote)),
    %% now in initialized mode
    %% Write files
    ok = file:write_file(filename:join([ClientPath, "client-only"]), "c1"),
    ok = file:write_file(filename:join([ServerPath, "server-only"]), "s1"),
    ok = file:write_file(filename:join([ServerPath, "shared"]), "sh1"),
    ok = file:write_file(filename:join([ClientPath, "shared"]), "sh2"),
    %% Track em
    ok = revault_dirmon_event:force_scan(Client, 5000),
    ok = revault_dirmon_event:force_scan(Server, 5000),
    %% Sync em
    ok = revault_fsm:sync(Client, Remote),
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

    %% Now when client 2 syncs, it gets the files and conflict files as well
    ct:pal("SECOND SYNC", []),
    ok = revault_fsm:sync(Client2, Remote),
    ?assertEqual({ok, <<"c1">>}, file:read_file(filename:join([ClientPath2, "client-only"]))),
    ?assertEqual({ok, <<"s1">>}, file:read_file(filename:join([ClientPath2, "server-only"]))),
    %% conflicting files are marked, but working files aren't sync'd since they didn't exist here
    ?assertEqual({error, enoent}, file:read_file(filename:join([ClientPath2, "shared"]))),
    ?assertEqual(
        {ok, <<"1C56416E18E2FE12E55CB8DE8AB3BB54DEDEC94C942520403CCD2E8DCA7BF8D5\n"
               "D6BE7FB89A392FE342033E3ECCFF9CADFC4A58A19316E162E079D662762CE8B8">>},
        file:read_file(filename:join([ClientPath2, "shared.conflict"]))
    ),
    ?assertEqual({ok, <<"sh1">>}, file:read_file(filename:join([ClientPath2, "shared.D6BE7FB8"]))),
    ?assertEqual({ok, <<"sh2">>}, file:read_file(filename:join([ClientPath2, "shared.1C56416E"]))),
    ok.

prevent_server_clash() ->
    [{doc, "A client from a different server cannot connect to the wrong one "
           "as it is protected by a UUID."},
     {timetrap, timer:seconds(5)}].
prevent_server_clash(Config) ->
    Client = ?config(name, Config),
    Server = ?config(server, Config),
    Remote = (?config(peer, Config))(Server),
    ClientPath = ?config(path, Config),
    ServerPid = ?config(fsm, Config),
    {ok, _ServId1} = revault_fsm:id(Server),
    {ok, _} = revault_fsm_sup:start_fsm(
        ?config(db_dir, Config),
        Client,
        ClientPath,
        ?config(interval, Config),
        (?config(callback, Config))(Client)
    ),
    ok = revault_fsm:client(Client),
    {ok, _ClientId} = revault_fsm:id(Client, Remote),
    %% Now here, to simulate connecting to a different server with a different ID,
    %% we could set up a whole new harness with a varied config, more ports, and
    %% get the client to try and connect to that one. Instead what we're going to
    %% do is live-edit the server's state to give it a different UUID and see
    %% that we're properly denying the connection.
    {_, OldData} = sys:get_state(ServerPid),
    OldUUID = element(?UUID_RECORD_POS, OldData),
    NewUUID = uuid:get_v4(),
    sys:replace_state(
      ServerPid,
      fun({State, Data}) -> {State, setelement(?UUID_RECORD_POS, Data, NewUUID)} end
    ),
    ct:pal("swapped ~p for ~p", [OldUUID, NewUUID]),
    %% Try to connect the client to that server, and see it fail
    ?assertMatch({error, {invalid_peer, OldUUID}}, revault_fsm:sync(Client, Remote)),
    ok.

%% TODO: dealing with interrupted connections?
%% TODO: using OTel to create FSM-level traces via debug hooks and keeping
%%       them distinct from specific request-long traces


%%%%%%%%%%%%%%
%%% HELPER %%%
%%%%%%%%%%%%%%
block() ->
    application:set_env(revault, ?MODULE, block).

unblock() ->
    application:set_env(revault, ?MODULE, unblock).

block_loop() ->
    case application:get_env(revault, ?MODULE, unblock) of
        block -> timer:sleep(10), block_loop();
        _ -> ok
    end.

wait_dead([]) ->
    ok;
wait_dead([Pid|Rest]) when is_pid(Pid) ->
    case erlang:is_process_alive(Pid) of
        true ->
            timer:sleep(100),
            wait_dead([Pid|Rest]);
        false ->
            wait_dead(Rest)
    end;
wait_dead([Name|Rest]) when is_atom(Name) ->
    case whereis(Name) of
        undefined ->
            wait_dead(Rest);
        _ ->
            timer:sleep(100),
            wait_dead([Name|Rest])
    end.

wait_alive([]) ->
    ok;
wait_alive([Name|Rest]) when is_atom(Name) ->
    case whereis(Name) of
        undefined ->
            timer:sleep(100),
            wait_alive([Name|Rest]);
        _ ->
            wait_alive(Rest)
    end;
wait_alive([Name|Rest]) ->
    case gproc:where(Name) of
        undefined ->
            timer:sleep(100),
            wait_alive([Name|Rest]);
        _ ->
            wait_alive(Rest)
    end.
