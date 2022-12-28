-module(revault_cli).
-behaviour(cli).
-mode(compile).
%% API exports
-export([main/1, cli/0]).
%% Behaviour exports
-export([list/1, scan/1, sync/1, status/1, 'generate-keys'/1]).


%% Name of the main running host, as specified in `config/vm.args'
-define(DEFAULT_NODE, 'revault@127.0.0.1').

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
                #{name => node, nargs => 'maybe', type => atom, default => ?DEFAULT_NODE,
                  long => "node", help => "ReVault instance to connect to"}
            ]
        },
        "scan" => #{
            arguments => [
                #{name => node, nargs => 'maybe', type => atom, default => ?DEFAULT_NODE,
                  long => "node", help => "ReVault instance to connect to"},
                #{name => dirs, long => "dirs",
                  nargs => nonempty_list, type => binary, help => "Name of the directory to scan"}
            ]
        },
        "sync" => #{
            arguments => [
                #{name => node, nargs => 'maybe', type => atom, default => ?DEFAULT_NODE,
                  long => "node", help => "ReVault instance to connect to"},
                #{name => peer, nargs => 1, type => binary,
                  long => "peer", help => "ReVault peer name with which to sync"},
                #{name => dirs, nargs => nonempty_list, long => "dirs",
                  type => binary, help => "Name of the directory to scan"}
            ]
        },
        "status" => #{
            arguments => [
                #{name => node, nargs => 'maybe', type => atom, default => ?DEFAULT_NODE,
                  long => "node", help => "ReVault instance to connect to"}
            ]
        },
        "generate-keys" => #{
            arguments => [
                #{name => node, nargs => 'maybe', type => atom, default => ?DEFAULT_NODE,
                  long => "node", help => "ReVault instance to connect to"},
                #{name => certname, nargs => 'maybe', long => "name",
                  type => string, default => "revault",
                  help => "Name of the key files generated"},
                #{name => path, nargs => 'maybe', long => "path",
                  type => string, default => "./",
                  help => "Directory where the key files will be placed"}
            ]
        }
    }}.


%%%%%%%%%%%%%%%%%%%%%%%%
%%% BEHAVIOR EXPORTS %%%
%%%%%%%%%%%%%%%%%%%%%%%%
list(#{node := Node}) ->
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

scan(_Args = #{node := Node, dirs := Dirs}) ->
    maybe
        ok ?= connect(Node),
        ok ?= revault_node(Node),
        show(scan_dirs(Node, Dirs))
    else
        {error, no_dist} ->
            io:format("Erlang distribution seems to be off.~n");
        {error, connection_failed} ->
            io:format("Erlang distribution connection to ~p failed.~n", [Node])
    end;
scan(Args = #{node := Node}) ->
    %% find all directories allowed
    maybe
        ok ?= connect(Node),
        ok ?= revault_node(Node),
        {config, _, #{<<"dirs">> := Map}} ?= config(Node),
        scan(Args#{dirs => maps:keys(Map)})
    else
        _ -> scan(Args#{dirs => []})
    end.


sync(#{node := Node, dirs := Dirs = [_|_], peer := Peer}) ->
    maybe
        ok ?= connect(Node),
        ok ?= revault_node(Node),
        show(sync_dirs(Node, Peer, Dirs))
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
    [{scan, Name,
      rpc:call(Node, revault_dirmon_event, force_scan, [Name, infinity])}
     || Name <- Dirs].

sync_dirs(Node, Remote, Dirs) ->
    scan_dirs(Node, Dirs)
    ++
    [{sync, Name, Remote,
      rpc:call(Node, revault_fsm, sync, [Name, Remote])}
     || Name <- Dirs].

show(List) when is_list(List) ->
    [show(X) || X <- List];
show({config, Path, Config}) ->
    io:format("Config parsed from ~ts:~n~p~n", [Path, Config]);
show({scan, Dir, Res}) ->
    io:format("Scanning ~ts: ~p~n", [Dir, Res]);
show({sync, Dir, Peer, Res}) ->
    io:format("Syncing ~ts with ~ts: ~p~n", [Dir, Peer, Res]).

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
