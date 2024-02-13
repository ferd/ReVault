%% Shared header for records and types used across the TCP functionality
%% within revault.
-define(ACCEPT_WAIT, 100).
-define(SERVER, {via, gproc, {n, l, {tcp, serv, shared}}}).
-define(CLIENT(Name), {via, gproc, {n, l, {tcp, client, Name}}}).
-record(client, {name, dirs, dir, auth, opts, sock, buf = <<>>}).
-record(serv, {names=#{}, dirs, opts, sock, acceptor, workers=#{}}).
-record(conn, {localname, sock, dirs, buf = <<>>}).
