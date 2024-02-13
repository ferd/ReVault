%%% Shared definitions between revault_tls_serv and revault_tls_client.
%%% Both the client and the server implement a process with a reception
%%% loop to which this module can send messages and read from them.
%%%
%%% There is one internal API to be used by revault_sync_fsm, and
%%% one internal API to be used by the client and servers.
-module(revault_tls).

-include_lib("public_key/include/public_key.hrl").
-include("revault_data_wrapper.hrl").
-include("revault_tls.hrl").

-record(buf, {acc=[<<>>], seen=0, needed=0}).

%% callbacks from within the FSM
-export([callback/1, mode/2, peer/4, accept_peer/3, unpeer/3, send/3, reply/4, unpack/2]).
%% shared functions related to data transport and serialization
-export([wrap/1, unwrap/1, unwrap_all/1, unpack/1, send_local/2,
        buf_add/2, buf_new/0, buf_size/1]).
%% shared functions related to TLS certs
-export([pin_certfile_opts_server/1, pin_certfile_opts_client/1,
         pin_certfiles_opts_server/1, pin_certfiles_opts_client/1,
         make_selfsigned_cert/2]).

-record(state, {proc, name, dirs, mode, serv_conn}).
-type state() :: term().
-type cb_state() :: {?MODULE, state()}.
-type buf() :: #buf{}.
-export_type([state/0, buf/0]).

-if(?OTP_RELEASE < 26).
%% a bug prevents TLS 1.3 from working well with cert pinning in versions prior
%% to OTP-26.rc-1:
%% https://erlangforums.com/t/server-side-tls-cert-validation-woes-in-tls-1-3/1586
-define(TLS_VSN, 'tlsv1.2').
-else.
-define(TLS_VSN, 'tlsv1.3').
-endif.

-spec callback(term()) -> state().
callback({Name, DirOpts}) ->
    {?MODULE, #state{proc=Name, name=Name, dirs=DirOpts}};
callback({Proc, Name, DirOpts}) ->
    {?MODULE, #state{proc=Proc, name=Name, dirs=DirOpts}}.

-spec mode(client|server, state()) -> {term(), cb_state()}.
mode(Mode, S=#state{proc=Proc, name=Name, dirs=DirOpts}) ->
    Res = case Mode of
        client ->
            revault_protocols_tls_sup:start_client(Proc, DirOpts);
        server ->
            %% Assumes that all servers have the full DirOpts view if this is the
            %% first place to start it.
            case revault_protocols_tls_sup:start_server(DirOpts) of
                {ok, Pid} ->
                    revault_tls_serv:map(Name, Proc),
                    {ok, Pid};
                {error, {already_started, Pid}} ->
                    revault_tls_serv:map(Name, Proc),
                    {ok, Pid}
            end
    end,
    {Res, {?MODULE, S#state{mode=Mode}}}.

%% @doc only callable from the client-side.
peer(Local, Peer, Attrs, S=#state{name=Dir, dirs=#{<<"peers">> := Peers}}) ->
    case Peers of
        #{Peer := Map} ->
            Payload = {revault, make_ref(), revault_data_wrapper:peer(Dir, Attrs)},
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

-spec unwrap(buf()) -> {ok, ?VSN, term(), buf()} | {error, incomplete, buf()}.
unwrap(B=#buf{seen=S, needed=N, acc=Acc}) when S > 0, S >= N ->
    Bin = iolist_to_binary(lists:reverse(Acc)),
    <<Size:64/unsigned, ?VSN:16/unsigned, Payload/binary>> = Bin,
    <<Term:Size/binary, Rest/binary>> = Payload,
    {revault, Marker, Msg} = binary_to_term(Term),
    {ok, ?VSN, {revault, Marker, unpack(Msg)}, buf_add(Rest, buf_reset(B))};
unwrap(B=#buf{}) ->
    {error, incomplete, B}.

unpack({peer, ?VSN, Remote, Attrs}) -> {peer, Remote, Attrs};
unpack({ask, ?VSN}) -> ask;
unpack({ok, ?VSN}) -> ok;
unpack({error, ?VSN, R}) -> {error, R};
unpack({manifest, ?VSN}) -> manifest;
unpack({manifest, ?VSN, Data}) -> {manifest, Data};
unpack({file, ?VSN, Path, Meta, Bin}) -> {file, Path, Meta, Bin};
unpack({fetch, ?VSN, Path}) -> {fetch, Path};
unpack({sync_complete, ?VSN}) -> sync_complete;
unpack({deleted_file, ?VSN, Path, Meta}) -> {deleted_file, Path, Meta};
unpack({conflict_file, ?VSN, WorkPath, Path, Count, Meta, Bin}) ->
    {conflict_file, WorkPath, Path, Count, Meta, Bin};
unpack(Term) ->
    Term.

-spec unwrap_all(buf()) -> {[term()], buf()}.
unwrap_all(Buf) ->
    unwrap_all(Buf, []).

unwrap_all(Buf, Acc) ->
    case revault_tls:unwrap(Buf) of
        {error, incomplete, NewBuf} ->
            {lists:reverse(Acc), NewBuf};
        {ok, ?VSN, Payload, NewBuf} ->
            unwrap_all(NewBuf, [Payload|Acc])
    end.

-spec buf_add(binary(), buf()) -> buf().
buf_add(Bin, B=#buf{seen=0, needed=0, acc=Acc}) ->
    case iolist_to_binary([lists:reverse(Acc),Bin]) of
        <<Size:64/unsigned, ?VSN:16/unsigned, _/binary>> = NewBin ->
            %% Add 10 bytes to the needed size to cover the Size+Vsn
            B#buf{seen=byte_size(NewBin), needed=Size+10, acc=[NewBin]};
        IncompleteBin ->
            B#buf{acc=[IncompleteBin]}
    end;
buf_add(Bin, B=#buf{acc=Acc, seen=N}) ->
    B#buf{acc=[Bin|Acc], seen=N+byte_size(Bin)}.

-spec buf_new() -> buf().
buf_new() -> #buf{}.

-spec buf_reset(buf()) -> buf().
buf_reset(_) -> #buf{}.

-spec buf_size(buf()) -> non_neg_integer().
buf_size(#buf{seen=N}) -> N.


send_local(Proc, Payload) ->
    gproc:send({n, l, {revault_fsm, Proc}}, Payload).

pin_certfile_opts_client(FileNames) ->
    pin_certfile_opts(FileNames).

pin_certfile_opts_server(FileNames) ->
    [{fail_if_no_peer_cert, true}
     | pin_certfile_opts(FileNames)].

pin_certfiles_opts_client(FileNames) ->
    pin_certfiles_opts(FileNames).

pin_certfiles_opts_server(FileNames) ->
    [{fail_if_no_peer_cert, true}
     | pin_certfiles_opts(FileNames)].

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

%%%%%%%%%%%%%%%
%%% PRIVATE %%%
%%%%%%%%%%%%%%%
pin_certfile_opts(FileName) ->
    %% Lift tak's own parsing of certs and chains.
    %%
    %% Specifically here, carve out an exception: certs are local, not
    %% stored on s3 in s3 mode, so use `file' as a module rather than
    %% `revault_file'.
    case file:read_file(FileName) of
        {ok, Cert} ->
            tak:pem_to_ssl_options(Cert) ++
            [{verify, verify_peer}];
        {error, enoent} ->
            error({certificate_not_found, FileName})
    end.

pin_certfiles_opts(FileNames) ->
    pin_certfiles_opts(FileNames, [], []).

pin_certfiles_opts([], CAs, PinCerts) ->
    %% TODO: drop tlsv1.2 and mandate 1.3 when
    %% is resolved
    [{cacerts, CAs},
     {verify_fun, {fun verify_pins/3, PinCerts}},
     {versions, [?TLS_VSN]},
     {verify, verify_peer}];
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
