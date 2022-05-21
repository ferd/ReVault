-module(maestro_cfg).
-export([parse/1, parse_file/0, parse_file/1, config_path/0]).

-type t() :: #{binary() := binary() | #{binary() := map()}}.
-export_type([t/0]).

-define(DEFAULT_INTERVAL_SECONDS, 60).

-spec parse(unicode:chardata()) -> {ok, t()} | {error, term()}.
parse(Chardata) ->
    case tomerl:parse(Chardata) of
        {ok, Cfg} -> normalize(Cfg);
        {error, Reason} -> {error, Reason}
    end.

-spec parse_file() -> {ok, t()} | {error, term()}.
parse_file() ->
    %% ensure the call is mockable for tests by making it fully qualified.
    parse_file(?MODULE:config_path()).

-spec parse_file(file:filename()) -> {ok, t()} | {error, term()}.
parse_file(FileName) ->
    case tomerl:read_file(FileName) of
        {ok, Cfg} -> normalize(Cfg);
        {error, Reason} -> {error, Reason}
    end.

normalize(Cfg) ->
    try
        Db = normalize_db(Cfg),
        {ok, Dirs} = tomerl:get(Cfg, [<<"dirs">>]),
        {ok, Peers} = tomerl:get(Cfg, [<<"peers">>]),
        {ok, Server} = tomerl:get(Cfg, [<<"server">>]),
        NormDirs = normalize_dirs(Dirs),
        DirNames = dirnames(NormDirs),
        {ok, Cfg#{<<"db">> => Db,
                  <<"dirs">> := NormDirs,
                  <<"peers">> := normalize_peers(Peers, DirNames),
                  <<"server">> := normalize_server(Server, DirNames)}}
    catch
        error:badmatch -> {error, missing_section};
        error:{badkey, K}:S -> {error, {missing_key, K, S}};
        throw:Reason -> {error, Reason}
    end.

normalize_db(Cfg) ->
    Map = case tomerl:get(Cfg, [<<"db">>]) of
        {ok, DbMap} -> DbMap;
        {error, not_found} -> #{}
    end,
    Path = maps:get(<<"path">>, Map, default_db_path()),
    #{<<"path">> => Path}.

normalize_dirs(Map) ->
    maps:fold(fun normalize_dir/3, #{}, Map).

normalize_peers(Map, Dirnames) ->
    maps:fold(fun(K, M, Acc) -> normalize_peer(K, M, Acc, Dirnames) end,
              #{}, Map).

normalize_server(Map, Dirnames) ->
    Map#{<<"auth">> => normalize_serv_auth(
            maps:get(<<"auth">>, Map),
            Dirnames)
    }.

normalize_dir(Key, Map, Acc) ->
    Acc#{Key => #{
           <<"interval">> => maps:get(<<"interval">>, Map,
                                      ?DEFAULT_INTERVAL_SECONDS),
           <<"path">> => maps:get(<<"path">>, Map),
           <<"ignore">> => maps:get(<<"ignore">>, Map, [])
          }
    }.

normalize_peer(Key, Map, Acc, Dirnames) ->
    Acc#{Key => #{
           <<"sync">> => maps:get(<<"sync">>, Map, Dirnames),
           <<"url">> => maps:get(<<"url">>, Map),
           <<"auth">> => normalize_peer_auth(maps:get(<<"auth">>, Map))
          }
    }.

normalize_peer_auth(Map) ->
    normalize_peer_auth(maps:get(<<"type">>, Map), Map).

normalize_peer_auth(<<"none">>, Map) ->
    Map;
normalize_peer_auth(<<"tls">>, Map) ->
    _ = maps:get(<<"certfile">>, Map),
    _ = maps:get(<<"fingerprint_sha">>, Map),
    Map.

normalize_serv_auth(Map, Dirnames) ->
    maps:fold(fun(K, V, Acc) -> normalize_serv_auth(K, V, Acc, Dirnames) end,
              #{}, Map).

normalize_serv_auth(<<"none">>, Map, Acc, Dirnames) ->
    Acc#{<<"none">> => #{
        <<"status">> => status(maps:get(<<"status">>, Map, <<"enabled">>)),
        <<"mode">> => mode(maps:get(<<"mode">>, Map, <<"read/write">>)),
        <<"sync">> => maps:get(<<"sync">>, Map, Dirnames),
        <<"port">> => maps:get(<<"port">>, Map)
    }};
normalize_serv_auth(<<"tls">>, Map, Acc, Dirnames) ->
    Acc#{<<"tls">> => #{
        <<"status">> => status(maps:get(<<"status">>, Map, <<"enabled">>)),
        <<"port">> => maps:get(<<"port">>, Map),
        <<"certfile">> => maps:get(<<"certfile">>, Map),
        <<"authorized">> =>
            auth_certs(maps:get(<<"authorized">>, Map), Dirnames)
    }}.

auth_certs(Map, Dirnames) ->
    maps:fold(fun(K, V, Acc) -> auth_certs(K, V, Acc, Dirnames) end,
              #{}, Map).

auth_certs(Name, Map, Acc, Dirnames) ->
    Acc#{Name => #{
        <<"mode">> => mode(maps:get(<<"mode">>, Map, <<"read/write">>)),
        <<"sync">> => maps:get(<<"sync">>, Map, Dirnames),
        <<"fingerprint_sha">> => maps:get(<<"fingerprint_sha">>, Map)
    }}.

dirnames(Map) -> maps:keys(Map).

status(<<"disabled">>) -> disabled;
status(<<"enabled">>) -> enabled.

mode(<<"read/write">>) -> read_write;
mode(<<"read">>) -> read.

-spec config_path() -> file:filename().
config_path() ->
    filename:join(config_dir(), "config.toml").

default_db_path() ->
    filename:join(config_dir(), "db").

config_dir() ->
    Opts = case os:type() of
        {unix, darwin} -> % OSX, use XDG format
            #{os => linux};
        _ ->
            #{}
    end,
    filename:basedir(user_config, "ReVault", Opts).
