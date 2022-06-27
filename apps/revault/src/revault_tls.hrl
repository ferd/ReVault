%% Shared header for records and types used across the TCP functionality
%% within revault.
-define(VSN, 1).
-define(ACCEPT_WAIT, 100). % interval for accept loops
-define(HANDSHAKE_WAIT, 10000). % give up after 10 seconds
-define(SERVER(Name), {via, gproc, {n, l, {tls, serv, Name}}}).
-define(CLIENT(Name), {via, gproc, {n, l, {tls, client, Name}}}).
-record(client, {name, dirs, dir, auth, opts, sock, buf = <<>>}).
-record(serv, {name, dirs, opts, sock, workers=#{}}).
-record(conn, {localname, sock, dirs, buf = <<>>}).

