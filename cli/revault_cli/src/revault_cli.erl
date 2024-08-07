-module(revault_cli).
-behaviour(cli).
-mode(compile).
%% API exports
-export([main/1, cli/0]).
%% Behaviour exports
-export([list/1, scan/1, sync/1, status/1, 'generate-keys'/1, seed/1, 'remote-seed'/1]).


%% Name of the main running host, as specified in `config/vm.args'
-define(DEFAULT_NODE, "revault@" ++ hd(tl(string:tokens(atom_to_list(node()), "@")))).

%%====================================================================
%% API functions
%%====================================================================

%% escript Entry point
main(Args) ->
    cli:run(Args, #{progname => "revault-cli"}).

cli() ->
    #{commands => #{
        "list" => #{
            arguments => [
                #{name => node, nargs => 'maybe', type => {string, ".*@.*"}, default => ?DEFAULT_NODE,
                  long => "node", help => "ReVault instance to connect to"}
            ]
        },
        "scan" => #{
            arguments => [
                #{name => node, nargs => 'maybe', type => {string, ".*@.*"}, default => ?DEFAULT_NODE,
                  long => "node", help => "ReVault instance to connect to"},
                #{name => dirs, long => "dirs",
                  nargs => nonempty_list, type => binary, help => "Name of the directory to scan"}
            ]
        },
        "sync" => #{
            arguments => [
                #{name => node, nargs => 'maybe', type => {string, ".*@.*"}, default => ?DEFAULT_NODE,
                  long => "node", help => "ReVault instance to connect to"},
                #{name => peer, nargs => 1, type => binary,
                  long => "peer", help => "ReVault peer name with which to sync"},
                #{name => dirs, nargs => nonempty_list, long => "dirs",
                  type => binary, help => "Name of the directory to scan"}
            ]
        },
        "status" => #{
            arguments => [
                #{name => node, nargs => 'maybe', type => {string, ".*@.*"}, default => ?DEFAULT_NODE,
                  long => "node", help => "ReVault instance to connect to"}
            ]
        },
        "generate-keys" => #{
            arguments => [
                #{name => certname, nargs => 'maybe', long => "name",
                  type => string, default => "revault",
                  help => "Name of the key files generated"},
                #{name => path, nargs => 'maybe', long => "path",
                  type => string, default => "./",
                  help => "Directory where the key files will be placed"}
            ]
        },
        "seed" => #{
            arguments => [
                #{name => node, nargs => 1, type => {string, ".*@.*"}, default => ?DEFAULT_NODE,
                  long => "node", help => "ReVault instance to connect to and from which to fork. Must be local."},
                #{name => path, nargs => 1, long => "path", type => string, default => "./forked/",
                  help => "path of the base directory where the forked data will be located."},
                #{name => dirs, nargs => nonempty_list , long => "dirs",
                  type => binary, help => "Name of the directories to fork."}
            ]
        },
        "remote-seed" => #{
            arguments => [
                #{name => node, nargs => 'maybe', type => {string, ".*@.*"}, default => ?DEFAULT_NODE,
                  long => "node", help => "ReVault instance to connect to"},
                #{name => peer, nargs => 1, type => binary,
                  long => "peer", help => "ReVault peer name from which to seed."},
                #{name => dirs, nargs => nonempty_list , long => "dirs",
                  type => binary, help => "Name of the directories to fork."}
            ]
        }
    }}.


%%%%%%%%%%%%%%%%%%%%%%%%
%%% BEHAVIOR EXPORTS %%%
%%%%%%%%%%%%%%%%%%%%%%%%
list(#{node := NodeStr}) ->
    Node = list_to_atom(NodeStr),
    maybe
        ok ?= connect(Node),
        ok ?= revault_node(Node),
        show(config(Node))
    else
        {error, no_dist} ->
            io:format("Erlang distribution seems to be off.~n");
        {error, connection_failed} ->
            io:format("Erlang distribution connection to ~p failed.~n", [Node])
    end.

scan(_Args = #{node := NodeStr, dirs := Dirs}) ->
    Node = list_to_atom(NodeStr),
    maybe
        ok ?= connect(Node),
        ok ?= revault_node(Node),
        ok ?= scan_dirs(Node, Dirs)
    else
        {error, no_dist} ->
            io:format("Erlang distribution seems to be off.~n");
        {error, connection_failed} ->
            io:format("Erlang distribution connection to ~p failed.~n", [Node])
    end;
scan(Args = #{node := NodeStr}) ->
    Node = list_to_atom(NodeStr),
    %% find all directories allowed
    maybe
        ok ?= connect(Node),
        ok ?= revault_node(Node),
        {config, _, #{<<"dirs">> := Map}} ?= config(Node),
        scan(Args#{dirs => maps:keys(Map)})
    else
        _ -> scan(Args#{dirs => []})
    end.


sync(#{node := NodeStr, dirs := Dirs = [_|_], peer := [Peer]}) ->
    Node = list_to_atom(NodeStr),
    maybe
        ok ?= connect(Node),
        ok ?= revault_node(Node),
        ok ?= sync_dirs(Node, Peer, Dirs)
    else
        {error, no_dist} ->
            io:format("Erlang distribution seems to be off.~n");
        {error, connection_failed} ->
            io:format("Erlang distribution connection to ~p failed.~n", [Node])
    end;
sync(Args = #{dirs := [_|_]}) ->
    io:format("Received ~p~n", [Args]),
    io:format("a -peer entry required to sync.~n");
sync(Args) ->
    io:format("Received ~p~n", [Args]),
    io:format("at least one -dirs entry required to sync.~n").


status(Args) ->
    io:format("running ~p~n", [{?LINE, Args}]).

'generate-keys'(#{certname := Name, path := Path}) ->
    Res = make_selfsigned_cert(Path, Name),
    io:format("~ts~n", [Res]).

seed(_Args = #{node := [NodeStr], path := Path, dirs := Dirs = [_|_]}) ->
    Node = list_to_atom(NodeStr),
    maybe
        ok ?= connect(Node),
        ok ?= revault_node(Node),
        AbsPath = filename:absname(Path),
        ok ?= filelib:ensure_path(Path),
        show(seed_fork(Node, AbsPath, Dirs))
    else
        {error, no_dist} ->
            io:format("Erlang distribution seems to be off.~n");
        {error, connection_failed} ->
            io:format("Erlang distribution connection to ~p failed.~n", [Node]);
        {error, Posix} ->
            io:format("Could not ensure path ~p, failed with ~p.~n", [Path, Posix])
    end.

'remote-seed'(#{node := NodeStr, dirs := Dirs = [_|_], peer := [Peer]}) ->
    Node = list_to_atom(NodeStr),
    maybe
        ok ?= connect(Node),
        ok ?= revault_node(Node),
        ok ?= all_ok(seed_dirs(Node, Peer, Dirs), Dirs)
    else
        {error, no_dist} ->
            io:format("Erlang distribution seems to be off.~n");
        {error, connection_failed} ->
            io:format("Erlang distribution connection to ~p failed.~n", [Node])
    end;
'remote-seed'(Args = #{dirs := [_|_]}) ->
    io:format("Received ~p~n", [Args]),
    io:format("a -peer entry required to sync.~n");
'remote-seed'(Args) ->
    io:format("Received ~p~n", [Args]),
    io:format("at least one -dirs entry required to sync.~n").

%%%%%%%%%%%%%%%%
 %%% PRIVATE %%%
%%%%%%%%%%%%%%%%
-spec connect(atom()) -> ok | {error, atom()}.
connect(Node) ->
    case net_kernel:connect_node(Node) of
        ignored -> {error, no_dist};
        false -> {error, connection_failed};
        true -> ok
    end.

-spec revault_node(atom()) -> ok | {error, term()}.
revault_node(Node) ->
    try rpc:call(Node, maestro_loader, status, []) of
        current -> ok;
        outdated -> ok;
        last_valid -> ok;
        _ -> {error, unknown_status}
    catch
        E:R -> {error, {rpc, {E,R}}}
    end.

config(Node) ->
    {ok, Path, Config} = rpc:call(Node, maestro_loader, current, []),
    {config, Path, Config}.

scan_dirs(Node, Dirs) ->
    all_ok(scan_dirs_(Node, Dirs), Dirs).

scan_dirs_(_, []) ->
    [];
scan_dirs_(Node, [Name|Dirs]) ->
    io:format("Scanning ~ts: ", [Name]),
    Res = rpc:call(Node, revault_dirmon_event, force_scan, [Name, infinity]),
    io:format("~p~n", [Res]),
    [Res | scan_dirs_(Node, Dirs)].

sync_dirs(Node, Remote, Dirs) ->
    case scan_dirs(Node, Dirs) of
        ok -> all_ok(sync_dirs_(Node, Remote, Dirs), Dirs);
        Other -> Other
    end.

sync_dirs_(_Node, _Remote, []) ->
    [];
sync_dirs_(Node, Remote, [Name|Dirs]) ->
    io:format("Syncing ~ts with ~ts: ", [Name, Remote]),
    Res = rpc:call(Node, revault_fsm, sync, [Name, Remote]),
    io:format("~p~n", [Res]),
    [Res | sync_dirs_(Node, Remote, Dirs)].

seed_dirs(_Node, _Remote, []) ->
    [];
seed_dirs(Node, Remote, [Name|Dirs]) ->
    io:format("Seeding ~ts from ~ts: ", [Name, Remote]),
    Res = rpc:call(Node, revault_fsm, id, [Name, Remote]),
    io:format("~p~n", [Res]),
    [Res | seed_dirs(Node, Remote, Dirs)].

seed_fork(Node, Path, Dirs) ->
    [{fork, Name, Path,
      rpc:call(Node, revault_fsm, seed_fork, [Name, Path])}
     || Name <- Dirs].

show(List) when is_list(List) ->
    [show(X) || X <- List];
show({config, Path, Config}) ->
    io:format("Config parsed from ~ts:~n~p~n", [Path, Config]);
show({sync, Dir, Peer, Res}) ->
    io:format("Syncing ~ts with ~ts: ~p~n", [Dir, Peer, Res]);
show({fork, Name, Path, Res}) ->
    io:format("Seeding ~ts in ~p: ~p~n", [Name, Path, Res]).

all_ok(L, Keys) -> all_ok(L, Keys, []).

all_ok([], [], []) -> ok;
all_ok([], [], Bad) -> {error, Bad};
all_ok([ok|T], [_|Ks], Bad) -> all_ok(T, Ks, Bad);
all_ok([{ok,_}|T], [_|Ks], Bad) -> all_ok(T, Ks, Bad);
all_ok([H|T], [K|Ks], Bad) -> all_ok(T, Ks, [{K,H}|Bad]).

%% Copied from revault_tls
make_selfsigned_cert(Dir, CertName) ->
    check_openssl_vsn(),

    Key = filename:join(Dir, CertName ++ ".key"),
    Cert = filename:join(Dir, CertName ++ ".crt"),
    ok = filelib:ensure_dir(Cert),
    Cmd = io_lib:format(
        "openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes "
        "-keyout '~ts' -out '~ts' -subj '/CN=example.org' "
        "-addext 'subjectAltName=DNS:example.org,DNS:www.example.org,IP:127.0.0.1'",
        [Key, Cert] % TODO: escape quotes
    ),
    os:cmd(Cmd).

check_openssl_vsn() ->
    Vsn = os:cmd("openssl version"),
    VsnMatch = "(Open|Libre)SSL ([0-9]+)\\.([0-9]+)\\.([0-9]+)",
    case re:run(Vsn, VsnMatch, [{capture, all_but_first, list}]) of
        {match, [Type, Major, Minor, Patch]} ->
            try
                check_openssl_vsn(Type, list_to_integer(Major),
                                  list_to_integer(Minor),
                                  list_to_integer(Patch))
            catch
                error:bad_vsn ->
                    error({openssl_vsn, Vsn})
            end;
        _ ->
            error({openssl_vsn, Vsn})
    end.

%% Using OpenSSL >= 1.1.1 or LibreSSL >= 3.1.0
check_openssl_vsn("Libre", A, B, _) when A > 3;
                                         A == 3, B >= 1 ->
    ok;
check_openssl_vsn("Open", A, B, C) when A > 1;
                                        A == 1, B > 1;
                                        A == 1, B == 1, C >= 1 ->
    ok;
check_openssl_vsn(_, _, _, _) ->
    error(bad_vsn).
