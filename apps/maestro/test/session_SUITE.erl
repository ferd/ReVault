%%% @doc Sample session using files and an external configuration.
%%% Should replicate what a user needs to do to see whether things work.
%%%
%%% This test suite uses a basic TLS set up, done over multiple VMs, with
%%% one VM running over each directory.
-module(session_SUITE).
-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() -> [setup_works, copy_and_sync].

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
        env => [{"REVAULT_CONFIG", ?config(conf_a, Config)}]
    }),
    {ok, PidB, NodeB} = ?CT_PEER(#{
        name => b, longnames => true, host => "127.0.0.1",
        env => [{"REVAULT_CONFIG", ?config(conf_b, Config)}]
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
    ct:pal("syncing on A"),
    current = rpc:call(NodeA, maestro_loader, status, []),
    ct:pal("booting B"),
    {ok, _} = rpc:call(NodeB, application, ensure_all_started, [maestro]),
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

%% To check: first setup, working while offline/online, how to sync.
setup_works(Config) ->
    {_, ServerNode} = ?config(peer_a, Config),
    {_, ClientNode} = ?config(peer_b, Config),
    Dir = <<"test">>,
    ?assertMatch({ok, _}, rpc:call(ServerNode, revault_fsm, id, [Dir])),
    %% initialize the client
    case rpc:call(ClientNode, revault_fsm, id, [Dir]) of
        undefined ->
            ?assertEqual(ok, rpc:call(ClientNode, revault_fsm, id, [Dir, <<"a">>])),
            ?assertMatch({ok, _}, rpc:call(ClientNode, revault_fsm, id, [Dir]));
        {ok, _} ->
            ok
    end,
    ok.

copy_and_sync(Config) ->
    %% make maestro boot all the things right on its own
    %% then just expose a call to sync on demand
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
