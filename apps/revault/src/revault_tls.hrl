%% Shared header for records and types used across the TCP functionality
%% within revault.
-define(VSN, 1).
-define(ACCEPT_WAIT, 100). % interval for accept loops
-define(HANDSHAKE_WAIT, 10000). % give up after 10 seconds
-define(SERVER, {via, gproc, {n, l, {tls, serv, shared}}}).
-define(CLIENT(Name), {via, gproc, {n, l, {tls, client, Name}}}).
-define(BACKOFF_THRESHOLD, 500).
-define(MIN_ACTIVE, 8).
-record(client, {name, dirs, peer, dir, auth, opts, sock,
                 recv = false, buf = revault_tls:buf_new(),
                 active=?MIN_ACTIVE, ctx = []}).
-record(serv, {names=#{}, dirs, opts, sock, acceptor, workers=#{}}).
-record(conn, {localname, sock, dirs,
               recv = false, buf = revault_tls:buf_new(),
               active = ?MIN_ACTIVE, ctx = []}).

