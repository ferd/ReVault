%%% @doc Sample session using files and an external configuration.
%%% Should replicate what a user needs to do to see whether things work.
%%%
%%% This test suite uses a basic TLS set up, done over multiple VMs, with
%%% one VM running over each directory.
-module(session_SUITE).
-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() -> [setup_works, copy_and_sync, conflict_and_sync,
          role_switch].

%% These values are hardcoded in the toml config files in the suite's
%% data_dir; changing them here requires changing them there too.
-define(TEST_PORT, 8022).

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(set_up_files, Config) ->
    DataDir = ?config(data_dir, Config),
    PrivDir = ?config(priv_dir, Config),
    ADir = filename:join([PrivDir, "a"]),
    BDir = filename:join([PrivDir, "b"]),
    ok = copy(filename:join([DataDir, "a"]), ADir),
    ok = filelib:ensure_path(BDir),
    ok = copy(filename:join([DataDir, "others"]),
              filename:join([PrivDir, "others"])),
    DbA = filename:join([PrivDir, "db", "a"]),
    DbB = filename:join([PrivDir, "db", "b"]),
    ok = filelib:ensure_path(DbA),
    ok = filelib:ensure_path(DbB),
    ConfA = filename:join([PrivDir, "others", "a.toml"]),
    ConfB = filename:join([PrivDir, "others", "b.toml"]),
    %% Hand it off to the test
    [{dir_a, ADir}, {dir_b, BDir},
     {conf_a, ConfA}, {conf_b, ConfB} | Config];
init_per_testcase(set_up_peers, ConfigTmp) ->
    Config = init_per_testcase(set_up_files, ConfigTmp),
    %% Set up the peer nodes
    {ok, PidA, NodeA} = ?CT_PEER(#{
        name => a, longnames => true, host => "127.0.0.1",
        env => [{"REVAULT_CONFIG", ?config(conf_a, Config)}],
        shutdown => close
    }),
    {ok, PidB, NodeB} = ?CT_PEER(#{
        name => b, longnames => true, host => "127.0.0.1",
        env => [{"REVAULT_CONFIG", ?config(conf_b, Config)}],
        shutdown => close
    }),
    ok = rpc:call(NodeA, file, set_cwd, [?config(priv_dir, Config)]),
    ok = rpc:call(NodeB, file, set_cwd, [?config(priv_dir, Config)]),
    [{peer_a, {PidA, NodeA}}, {peer_b, {PidB, NodeB}} | Config];
init_per_testcase(_, ConfigTmp) ->
    Config = init_per_testcase(set_up_peers, ConfigTmp),
    %% Start software
    {_PidA, NodeA} = ?config(peer_a, Config),
    {_PidB, NodeB} = ?config(peer_b, Config),
    %% Load the code paths to ensure full compatibility.
    Paths = code:get_path(),
    rpc:call(NodeA, code, add_pathsa, [Paths]),
    rpc:call(NodeB, code, add_pathsa, [Paths]),
    %% Boot the software.
    ct:pal("booting A"),
    {ok, _} = rpc:call(NodeA, application, ensure_all_started, [maestro]),
    ct:pal("booting B"),
    {ok, _} = rpc:call(NodeB, application, ensure_all_started, [maestro]),
    ct:pal("syncing on A"),
    current = rpc:call(NodeA, maestro_loader, status, []),
    ct:pal("syncing on B"),
    current = rpc:call(NodeB, maestro_loader, status, []),
    ct:pal("init complete"),
    Config.

end_per_testcase(_, Config) ->
    {PidA, _NodeA} = ?config(peer_a, Config),
    {PidB, _NodeB} = ?config(peer_b, Config),
    peer:stop(PidA),
    peer:stop(PidB),
    Config.

setup_works() ->
    [{doc, "The initialized peer nodes are running valid initialized FSMs"},
     {timetrap, timer:seconds(5)}].
setup_works(Config) ->
    {_, ServerNode} = ?config(peer_a, Config),
    {_, ClientNode} = ?config(peer_b, Config),
    Dir = <<"test">>,
    ?assertMatch({ok, _}, rpc:call(ServerNode, revault_fsm, id, [Dir])),
    ok = init_client(ClientNode, Dir, <<"a">>),
    ok.

copy_and_sync() ->
    [{doc, "Copying files end-to-end works fine, with conflicts omitted."},
     {timetrap, timer:seconds(5)}].
copy_and_sync(Config) ->
    {_, _ServerNode} = ?config(peer_a, Config),
    {_, ClientNode} = ?config(peer_b, Config),
    DirA = ?config(dir_a, Config),
    DirB = ?config(dir_b, Config),
    Dir = <<"test">>,
    ServerName = <<"a">>,
    %% make maestro boot all the things right on its own
    %% then just expose a call to sync on demand
    ok = init_client(ClientNode, Dir, ServerName),
    ?assertNotEqual(tree(DirA), tree(DirB)),
    ?assertEqual(ok, rpc:call(ClientNode, revault_fsm, sync, [Dir, ServerName])),
    ?assertEqual(tree(DirA), tree(DirB)),
    %% initial sync, now deal with some writes.
    copy(filename:join(?config(data_dir, Config), "b"), DirB),
    ?assertNotEqual(tree(DirA), tree(DirB)),
    ok = rpc:call(ClientNode, revault_dirmon_event, force_scan, [Dir, infinity]),
    ?assertEqual(ok, rpc:call(ClientNode, revault_fsm, sync, [Dir, ServerName])),
    ?assertEqual(tree(DirA), tree(DirB)),
    ok.

conflict_and_sync() ->
    [{doc, "Copying files end-to-end works fine, including conflicts "
           "and resolution."},
     {timetrap, timer:seconds(5)}].
conflict_and_sync(Config) ->
    {_, ServerNode} = ?config(peer_a, Config),
    {_, ClientNode} = ?config(peer_b, Config),
    DirA = ?config(dir_a, Config),
    DirB = ?config(dir_b, Config),
    Dir = <<"test">>,
    ServerName = <<"a">>,
    %% make maestro boot all the things right on its own
    %% then just expose a call to sync on demand
    ok = init_client(ClientNode, Dir, ServerName),
    %% Since the server has already noted its files and has a superset of
    %% an ID over the client, the client must sync once before its files
    %% are going to be tracked. Otherwise the first write automatically
    %% resolves all conflicts to the server as the superset.
    ?assertEqual(ok, rpc:call(ClientNode, revault_fsm, sync, [Dir, ServerName])),
    %% Now we can copy files and declare some conflicts.
    copy(filename:join(?config(data_dir, Config), "b"), DirB),
    file:write_file(filename:join(DirA, "shared.txt"), <<"ccc\n">>),
    ?assertNotEqual(tree(DirA), tree(DirB)),
    ok = rpc:call(ClientNode, revault_dirmon_event, force_scan, [Dir, infinity]),
    ok = rpc:call(ServerNode, revault_dirmon_event, force_scan, [Dir, infinity]),
    %% Now we should sync and get conflict files
    ?assertEqual(ok, rpc:call(ClientNode, revault_fsm, sync, [Dir, ServerName])),
    TreeA = tree(DirA),
    TreeB = tree(DirB),
    %% Files are the same aside from the working conflict file
    ?assertNotEqual(TreeA, TreeB),
    ?assertEqual(maps:without(["shared.txt"], TreeA),
                 maps:without(["shared.txt"], TreeB)),
    ?assertMatch(#{"shared.txt.conflict" := _,
                   "shared.txt.3CF9A1A8" := <<"bbb\n">>,
                   "shared.txt.5695D82A" := <<"ccc\n">>},
                 TreeA),
    ?assertNotMatch(#{"same.txt.conflict" := _}, TreeA),
    %% Fix the conflict on either side
    ok = file:delete(filename:join(DirA, "shared.txt.conflict")),
    ok = rpc:call(ServerNode, revault_dirmon_event, force_scan, [Dir, infinity]),
    ?assertEqual(ok, rpc:call(ClientNode, revault_fsm, sync, [Dir, ServerName])),
    TreeAFix = tree(DirA),
    TreeBFix = tree(DirB),
    ?assertEqual(TreeAFix, TreeBFix),
    ?assertNotMatch(#{"shared.txt.3CF9A1A8" := <<"bbb\n">>,
                      "shared.txt.5695D82A" := <<"ccc\n">>},
                    TreeAFix),
    ok.

role_switch() ->
    [{doc, "Once set up, instances can be doing both a client and a server "
           "role, and create non-centralized topologies so long as peers "
           "are accessible"},
     {timetrap, timer:seconds(5)}].
role_switch(Config) ->
    {_, ServerNode} = ?config(peer_a, Config),
    {_, ClientNode} = ?config(peer_b, Config),
    DirA = ?config(dir_a, Config),
    DirB = ?config(dir_b, Config),
    Dir = <<"test">>,
    ServerName = <<"a">>,
    %% make maestro boot all the things right on its own
    %% then just expose a call to sync on demand
    ok = init_client(ClientNode, Dir, ServerName),
    ?assertNotEqual(tree(DirA), tree(DirB)),
    ?assertEqual(ok, rpc:call(ClientNode, revault_fsm, sync, [Dir, ServerName])),
    ?assertEqual(tree(DirA), tree(DirB)),
    %% update the config
    DataDir = ?config(data_dir, Config),
    copy(filename:join([DataDir, "others", "a_switch.toml"]), ?config(conf_a, Config)),
    copy(filename:join([DataDir, "others", "b_switch.toml"]), ?config(conf_b, Config)),
    ?assertEqual(outdated, rpc:call(ServerNode, maestro_loader, status, [])),
    ?assertEqual(outdated, rpc:call(ClientNode, maestro_loader, status, [])),
    ct:pal("Reloading configs"),
    rpc:call(ServerNode, maestro_loader, reload, []),
    rpc:call(ClientNode, maestro_loader, reload, []),
    wait_until(fun() -> current == rpc:call(ServerNode, maestro_loader, status, []) end),
    wait_until(fun() -> current == rpc:call(ClientNode, maestro_loader, status, []) end),
    %% now deal with some writes.
    copy(filename:join(?config(data_dir, Config), "b"), DirB),
    ?assertNotEqual(tree(DirA), tree(DirB)),
    ok = rpc:call(ClientNode, revault_dirmon_event, force_scan, [Dir, infinity]),
    %% and sync in reverse order
    ClientName = <<"b">>,
    ?assertEqual(ok, rpc:call(ServerNode, revault_fsm, sync, [Dir, ClientName])),
    ?assertEqual(tree(DirA), tree(DirB)),
    ok.

%%%%%%%%%%%%%%%
%%% HELPERS %%%
%%%%%%%%%%%%%%%

%% @doc copy an entire directory to another location.
copy(From, To) ->
    case filelib:is_dir(From) of
        false ->
            ok = filelib:ensure_dir(To),
            {ok, _} = file:copy(From, To),
            ok;
        true ->
            {ok, Files} = file:list_dir(From),
            true = lists:all(
                     fun(X) -> X == ok end,
                     [copy(filename:join([From, F]), filename:join([To, F]))
                      || F <- Files]
                    ) == true,
            ok
    end.

tree(Dir) ->
    Res = tree(Dir, Dir, #{}),
    ct:pal("Tree ~p: ~p", [Dir, Res]),
    Res.

tree(Prefix, Path, Acc) ->
    case filelib:is_dir(Path) of
        false ->
            {ok, Bin} = file:read_file(Path),
            Acc#{drop_prefix(Prefix, Path) => Bin};
        true ->
            {ok, Files} = file:list_dir(Path),
            AbsFiles = [filename:join([Path, F]) || F <- Files],
            lists:foldl(fun(P,A) -> tree(Prefix, P, A) end, Acc, AbsFiles)
    end.

drop_prefix(Prefix, Path) ->
    filename:join(drop_prefix_(filename:split(Prefix), filename:split(Path))).

drop_prefix_([A|As], [A|Bs]) -> drop_prefix_(As, Bs);
drop_prefix_([], Bs) -> Bs.


init_client(ClientNode, Dir, Remote) ->
    case rpc:call(ClientNode, revault_fsm, id, [Dir]) of
        undefined ->
            ?assertEqual(ok, rpc:call(ClientNode, revault_fsm, id, [Dir, Remote])),
            ?assertMatch({ok, _}, rpc:call(ClientNode, revault_fsm, id, [Dir]));
        {ok, _} ->
            ok
    end,
    ok.

wait_until(Pred) ->
    case Pred() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait_until(Pred)
    end.
