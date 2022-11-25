%%% Shared definitions between revault_tls_serv and revault_tls_client.
%%% Both the client and the server implement a process with a reception
%%% loop to which this module can send messages and read from them.
%%%
%%% There is one internal API to be used by revault_sync_fsm, and
%%% one internal API to be used by the client and servers.
-module(revault_tls).

-include_lib("public_key/include/public_key.hrl").
-include("revault_tls.hrl").

%% stack-specific calls to be made from an initializing process and that
%% are not generic.
-export([wrap/1, unwrap/1, send_local/2]).
%% callbacks from within the FSM
-export([callback/1, mode/2, peer/3, accept_peer/3, unpeer/3, send/3, reply/4, unpack/2]).
%% shared functions
-export([pin_certfile_opts/1, pin_certfiles_opts/1, make_selfsigned_cert/2]).

-record(state, {proc, name, dirs, mode, serv_conn}).
-type state() :: term().
-type cb_state() :: {?MODULE, state()}.
-export_type([state/0]).

-spec callback(term()) -> state().
callback({Name, DirOpts}) ->
    {?MODULE, #state{proc=Name, name=Name, dirs=DirOpts}};
callback({Proc, Name, DirOpts}) ->
    {?MODULE, #state{proc=Proc, name=Name, dirs=DirOpts}}.

-spec mode(client|server, state()) -> {term(), cb_state()}.
mode(Mode, S=#state{proc=Proc, dirs=DirOpts}) ->
    Res = case Mode of
        client ->
            revault_protocols_tls_sup:start_client(Proc, DirOpts);
        server ->
            revault_protocols_tls_sup:start_server(Proc, DirOpts)
    end,
    {Res, {?MODULE, S#state{mode=Mode}}}.

%% @doc only callable from the client-side.
peer(Local, Peer, S=#state{name=Dir, dirs=#{<<"peers">> := Peers}}) ->
    case Peers of
        #{Peer := Map} ->
            Payload = {revault, make_ref(), revault_data_wrapper:peer(Dir)},
            {revault_tls_client:peer(Local, Peer, Map, Payload), {?MODULE, S}};
        _ ->
            {{error, unknown_peer}, {?MODULE, S}}
    end.

accept_peer(Remote, Marker, S=#state{proc=Proc}) ->
    {ok, Conn} = revault_tls_serv:accept_peer(Proc, Remote, Marker),
    {ok, {?MODULE, S#state{serv_conn=Conn}}}.

unpeer(Proc, Remote, S=#state{mode=client}) ->
    {revault_tls_client:unpeer(Proc, Remote),
     {?MODULE, S}};
unpeer(Proc, Remote, S=#state{mode=server, serv_conn=Conn}) ->
    {revault_tls_serv:unpeer(Proc, Remote, Conn),
     {?MODULE, S#state{serv_conn=undefined}}}.

%% @doc only callable from the client-side, server always replies.
send(Remote, Payload, S=#state{proc=Proc, mode=client}) ->
    Marker = make_ref(),
    Res = case revault_tls_client:send(Proc, Remote, Marker, Payload) of
        ok -> {ok, Marker};
        Other -> Other
    end,
    {Res, {?MODULE, S}}.

% [Remote, Marker, revault_data_wrapper:ok()]),
reply(Remote, Marker, Payload, S=#state{proc=Proc, mode=client}) ->
    {revault_tls_client:reply(Proc, Remote, Marker, Payload),
     {?MODULE, S}};
reply(Remote, Marker, Payload, S=#state{proc=Proc, mode=server, serv_conn=Conn}) ->
    {revault_tls_serv:reply(Proc, Remote, Conn, Marker, Payload),
     {?MODULE, S}}.

unpack(_, _) -> error(undef).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% INTERNAL SHARED CALLS %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
wrap({revault, _Marker, _Payload}=Msg) ->
    Bin = term_to_binary(Msg, [compressed, {minor_version, 2}]),
    %% Tag by length to ease parsing.
    %% Prepare extra versions that could do things like deal with
    %% signed messages and add options and whatnot, or could let
    %% us spin up legacy state machines whenever that could happen.
    %%
    %% If we need more than 18,000 petabytes for a message and more
    %% than 65535 protocol versions, we're either very successful or
    %% failing in bad ways.
    <<(byte_size(Bin)):64/unsigned, ?VSN:16/unsigned, Bin/binary>>.

unwrap(<<Size:64/unsigned, ?VSN:16/unsigned, Payload/binary>>) ->
    case byte_size(Payload) of
        Incomplete when Incomplete < Size ->
            {error, incomplete};
        _ ->
            <<Term:Size/binary, Rest/binary>> = Payload,
            {revault, Marker, Msg} = binary_to_term(Term),
            {ok, ?VSN, {revault, Marker, unpack(Msg)}, Rest}
    end;
unwrap(<<_/binary>>) ->
    {error, incomplete}.

unpack({peer, ?VSN, Remote}) -> {peer, Remote};
unpack({ask, ?VSN}) -> ask;
unpack({ok, ?VSN}) -> ok;
unpack({error, ?VSN, R}) -> {error, R};
unpack({manifest, ?VSN}) -> manifest;
unpack({manifest, ?VSN, Data}) -> {manifest, Data};
unpack({file, ?VSN, Path, Meta, Bin}) -> {file, Path, Meta, Bin};
unpack({fetch, ?VSN, Path}) -> {fetch, Path};
unpack({sync_complete, ?VSN}) -> sync_complete;
unpack({conflict_file, ?VSN, WorkPath, Path, Count, Meta, Bin}) ->
    {conflict_file, WorkPath, Path, Count, Meta, Bin};
unpack(Term) ->
    Term.

send_local(Proc, Payload) ->
    gproc:send({n, l, {revault_fsm, Proc}}, Payload).

pin_certfile_opts(FileName) ->
    %% Lift tak's own parsing of certs and chains.
    case file:read_file(FileName) of
        {ok, Cert} ->
            tak:pem_to_ssl_options(Cert) ++
            [{verify, verify_peer},
             {fail_if_no_peer_cert, true}];
        {error, enoent} ->
            error({certificate_not_found, FileName})
    end.

pin_certfiles_opts(FileNames) ->
    pin_certfiles_opts(FileNames, [], []).

pin_certfiles_opts([], CAs, PinCerts) ->
    %% TODO: drop tlsv1.2 and mandate 1.3 when
    %% https://erlangforums.com/t/server-side-tls-cert-validation-woes-in-tls-1-3/1586
    %% is resolved
    [{cacerts, CAs},
     {verify_fun, {fun verify_pins/3, PinCerts}},
     {verify, verify_peer},
     {versions, ['tlsv1.2']}, % TODO: DROP
     {fail_if_no_peer_cert, true}];
pin_certfiles_opts([FileName|FileNames], CAs, PinCerts) ->
    %% Lift tak's own parsing, but then extract the option and allow setting
    %% multiple certificates. We need this because we have many possibly valid
    %% clients that can all be allowed to contact us as a server (whereas a
    %% client may expect to only contact one valid server).
    [{cacerts, [CADer]},
     {verify_fun, {_PinFun, PinCert}} | _] = pin_certfile_opts(FileName),
    pin_certfiles_opts(FileNames, [CADer|CAs], [PinCert|PinCerts]).

-spec verify_pins(OtpCert, Event, InitialUserState) ->
    {valid, UserState} | {fail, Reason :: term()} | {unknown, UserState}
    when
      OtpCert :: #'OTPCertificate'{},
      Event :: {bad_cert, Reason :: atom() | {revoked, atom()}}
             | {extension, #'Extension'{}} | valid | valid_peer,
      InitialUserState :: UserState,
      UserState :: term().
verify_pins(PinCert, valid_peer, PinCerts) ->
    case lists:member(PinCert, PinCerts) of
        true -> {valid, PinCerts};
        false -> {fail, {peer_cert_unknown, subject(PinCert)}}
    end;
verify_pins(_Cert, {extension, _}, PinCerts) ->
    {unknown, PinCerts};
verify_pins(PinCert, {bad_cert, selfsigned_peer}, PinCerts) ->
    case lists:member(PinCert, PinCerts) of
        true -> {valid, PinCerts};
        false -> {fail, {bad_cert, selfsigned_peer}}
    end;
verify_pins(_Cert, {bad_cert, _} = Reason, _PinCerts) ->
    {fail, Reason};
verify_pins(_Cert, valid, PinCerts) ->
    {valid, PinCerts}.

subject(#'OTPCertificate'{ tbsCertificate = TBS }) ->
    public_key:pkix_normalize_name(TBS#'OTPTBSCertificate'.subject).

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
