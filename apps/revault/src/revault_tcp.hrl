%% Shared header for records and types used across the TCP functionality
%% within revault.
-define(VSN, 1).
-define(ACCEPT_WAIT, 100).
-define(SERVER(Name), {via, gproc, {n, l, {tcp, serv, Name}}}).
-define(CLIENT(Name), {via, gproc, {n, l, {tcp, client, Name}}}).
-record(client, {name, dirs, dir, auth, opts, sock, buf = <<>>}).
-record(serv, {name, dirs, opts, sock, acceptor, workers=#{}}).
-record(conn, {localname, sock, dirs, buf = <<>>}).
