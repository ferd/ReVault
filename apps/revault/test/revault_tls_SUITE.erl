-module(revault_tls_SUITE).
-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all, nowarn_export_all]).

all() ->
    [pinning_client, pinning_server,
     unpinned_client, unpinned_server].

init_per_suite(Config) ->
    {ok, Apps} = application:ensure_all_started(ssl),
    CertPath = filename:join([?config(priv_dir, Config), "certs"]),
    %% Generate a few certs
    revault_tls:make_selfsigned_cert(CertPath, "server"),
    revault_tls:make_selfsigned_cert(CertPath, "client1"),
    revault_tls:make_selfsigned_cert(CertPath, "client2"),
    revault_tls:make_selfsigned_cert(CertPath, "other"),
    [{cert_dir, CertPath}, {apps, Apps} | Config].

end_per_suite(Config) ->
    [application:stop(App) || App <- lists:reverse(?config(apps, Config))],
    Config.

pinning_client() ->
    [{doc, "Ensure that the client can pin certs with generated options"}].
pinning_client(Config) ->
    ServerCert = filename:join(?config(cert_dir, Config), "server.crt"),
    ServerKey = filename:join(?config(cert_dir, Config), "server.key"),
    ClientCert = filename:join(?config(cert_dir, Config), "client1.crt"),
    ClientKey = filename:join(?config(cert_dir, Config), "client1.key"),
    {ok, _, Pid, {Ip, Port}} = start_server([{certfile, ServerCert}, {keyfile, ServerKey}]),
    ClientOpts = revault_tls:pin_certfile_opts(ServerCert)
               ++ [{certfile, ClientCert}, {keyfile, ClientKey}],
    {ok, Sock} = ssl:connect(Ip, Port, ClientOpts, 1000),
    ok = ssl:send(Sock, <<"test">>),
    receive
        {ssl, server, _, <<"test">>} -> ok;
        Other -> error(Other)
    after 500 ->
        error(test_timeout)
    end,
    Pid ! stop,
    ok.


pinning_server() ->
    [{doc, "Ensure that the server can pin certs with generated options"}].
pinning_server(Config) ->
    ServerCert = filename:join(?config(cert_dir, Config), "server.crt"),
    ServerKey = filename:join(?config(cert_dir, Config), "server.key"),
    Client1Cert = filename:join(?config(cert_dir, Config), "client1.crt"),
    Client1Key = filename:join(?config(cert_dir, Config), "client1.key"),
    Client2Cert = filename:join(?config(cert_dir, Config), "client2.crt"),
    _Client2Key = filename:join(?config(cert_dir, Config), "client2.key"),
    ServerOpts = revault_tls:pin_certfiles_opts([Client1Cert, Client2Cert])
               ++ [{certfile, ServerCert}, {keyfile, ServerKey}],
    ClientOpts = [{certfile, Client1Cert}, {keyfile, Client1Key}],
    {ok, _, Pid, {Ip, Port}} = start_server(ServerOpts),
    {ok, Sock} = ssl:connect(Ip, Port, ClientOpts, 1000),
    ok = ssl:send(Sock, <<"test">>),
    receive
        {ssl, server, _, <<"test">>} -> ok;
        Other -> error(Other)
    after 500 ->
        error(test_timeout)
    end,
    Pid ! stop,
    ok.

unpinned_client() ->
    [{doc, "A foreign cert doesn't make it through"}].
unpinned_client(Config) ->
    ServerCert = filename:join(?config(cert_dir, Config), "server.crt"),
    ServerKey = filename:join(?config(cert_dir, Config), "server.key"),
    Client1Cert = filename:join(?config(cert_dir, Config), "client1.crt"),
    _Client1Key = filename:join(?config(cert_dir, Config), "client1.key"),
    Client2Cert = filename:join(?config(cert_dir, Config), "client2.crt"),
    _Client2Key = filename:join(?config(cert_dir, Config), "client2.key"),
    OtherKey = filename:join(?config(cert_dir, Config), "other.key"),
    OtherCert = filename:join(?config(cert_dir, Config), "other.crt"),
    ServerOpts = revault_tls:pin_certfiles_opts([Client1Cert, Client2Cert])
               ++ [{certfile, ServerCert}, {keyfile, ServerKey}],
    ClientOpts = [{certfile, OtherCert}, {keyfile, OtherKey}],
    {ok, _, Pid, {Ip, Port}} = start_server(ServerOpts),
    case ssl:connect(Ip, Port, ClientOpts, 1000) of
        {ok, Sock} ->
            ok = ssl:send(Sock, <<"test">>),
            receive
                {ssl, server, _, <<"test">>} -> error(handshake_succeeded);
                {handshake_error, _} -> ok;
                Other -> error(Other)
            after 500 ->
                error(test_timeout)
            end;
        {error, {tls_alert, _}} ->
            ok
    end,
    Pid ! stop,
    ok.

unpinned_server() ->
    [{doc, "A foreign cert doesn't make it through"}].
unpinned_server(Config) ->
    ServerCert = filename:join(?config(cert_dir, Config), "server.crt"),
    _ServerKey = filename:join(?config(cert_dir, Config), "server.key"),
    Client1Cert = filename:join(?config(cert_dir, Config), "client1.crt"),
    Client1Key = filename:join(?config(cert_dir, Config), "client1.key"),
    Client2Cert = filename:join(?config(cert_dir, Config), "client2.crt"),
    _Client2Key = filename:join(?config(cert_dir, Config), "client2.key"),
    OtherKey = filename:join(?config(cert_dir, Config), "other.key"),
    OtherCert = filename:join(?config(cert_dir, Config), "other.crt"),
    ServerOpts = [{certfile, OtherCert}, {keyfile, OtherKey}],
    ClientOpts = revault_tls:pin_certfile_opts(ServerCert)
               ++ [{certfile, Client1Cert}, {keyfile, Client1Key}],
    {ok, _, Pid, {Ip, Port}} = start_server(ServerOpts),
    {error, {tls_alert, _}} = ssl:connect(Ip, Port, ClientOpts, 1000),
    Pid ! stop,
    ok.

%%%%%%%%%%%%%%%
%%% HELPERS %%%
%%%%%%%%%%%%%%%
start_server(Opts) ->
    AllOpts = [{reuseaddr, true}, {mode, binary}, {active, true},
               {ip, {127,0,0,1}} | Opts],
    {ok, Listen} = ssl:listen(0, AllOpts),
    {ok, {Ip, Port}} = ssl:sockname(Listen),
    Parent = self(),
    Pid = spawn_link(fun() -> listen(Parent, Listen) end),
    {ok, Listen, Pid, {Ip, Port}}.

listen(Pid, Listen) ->
    receive
        stop -> ok
    after 0 ->
        case ssl:transport_accept(Listen, 500) of
            {error, timeout} -> listen(Pid, Listen);
            {ok, Sock} -> handshake(Pid, Listen, Sock);
            {error, Reason} ->
                Pid ! {listen_error, Reason},
                listen(Pid, Listen)
        end
    end.

handshake(Pid, Listen, Sock) ->
    receive
        stop -> ok
    after 0 ->
        case ssl:handshake(Sock, 500) of
            {error, timeout} -> handshake(Pid, Listen, Sock);
            {ok, Tls} -> server(Pid, Listen, Tls);
            {error, Reason} ->
                Pid ! {handshake_error, Reason},
                listen(Pid, Listen)
        end
    end.

server(Pid, Listen, Sock) ->
    receive
        stop ->
            ok;
        {ssl, Sock, Data} ->
            Pid ! {ssl, server, Sock, Data},
            server(Pid, Listen, Sock);
        {ssl_closed, Sock} ->
            Pid ! {ssl_closed, server, Sock},
            listen(Pid, Listen);
        {ssl_error, Sock, Reason} ->
            Pid ! {ssl_error, server, Sock, Reason},
            listen(Pid, Listen)
    end.
