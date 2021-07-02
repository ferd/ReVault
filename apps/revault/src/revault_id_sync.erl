%%% @doc Protocol handler in charge of ITC ID synchronization.
%%%
%%% A core assumption of this module is that either parties being
%%% contacted are assumed to already be started and addressable.
%%%
%%% I.e. the idea here is to communicate with stateful processes
%%% we know are already in place into a running system, and provide
%%% concrete data that can then be handed off to some format-specific
%%% converters to deal with various encodings and wire formats.
%%%
%%% One important thing to note is that while we expect the server-side
%%% (with an already-created ID) to exist, we can't make that assumption
%%% from the client side if it does not exist yet, since booting it
%%% through `revault_dirmon_tracker' requires passing in the seed ID.
%%%
%%% This implies that the ID will be stored somewhere stateful, but the
%%% protocol here does not need to know where or how.
-module(revault_id_sync).
-export([new/0, ask/0, error/1, fork/2]).
-export([manifest/0, manifest/1, send_file/4, send_conflict_file/5, fetch_file/1,
         sync_complete/0]).
-export([send/2, reply/2, unpack/1]).
-define(VSN, 1).

new() ->
    revault_id:new().

ask() ->
    {ask, ?VSN}.

manifest() ->
    {manifest, ?VSN}.

manifest(Data) ->
    {manifest, ?VSN, Data}.

send_file(Path, Vsn, Hash, Bin) ->
    {file, ?VSN, Path, {Vsn, Hash}, Bin}.

send_conflict_file(WorkPath, Path, Vsn, Hash, Bin) ->
    {conflict_file, ?VSN, WorkPath, Path, Vsn, Hash, Bin}.

fetch_file(Path) ->
    {fetch, ?VSN, Path}.

sync_complete() ->
    {sync_complete, ?VSN}.

error(R) -> {error, ?VSN, R}.

fork({ask, ?VSN}, Id) ->
    {Keep, Send} = revault_id:fork(Id),
    {Keep, {reply, Send}}.

send({Name, Node}, Payload) ->
    Ref = make_ref(),
    From = self(),
    try
        erpc:call(Node, gproc, send,
                  [{n, l, {revault_sync_fsm, Name}},
                   {revault, {?MODULE, From, Ref}, Payload}]),
        {ok, Ref}
    catch
        E:R -> {error, {E,R}}
    end.

reply({?MODULE, From, Ref}, Payload) ->
    From ! {revault, {?MODULE, self(), Ref}, Payload},
    ok.

%% For this module, we just use raw erlang terms.
unpack({ask, ?VSN}) -> ask;
unpack({error, ?VSN, R}) -> {error, R};
unpack({manifest, ?VSN}) -> manifest;
unpack({manifest, ?VSN, Data}) -> {manifest, Data};
unpack({file, ?VSN, Path, Meta, Bin}) -> {file, Path, Meta, Bin};
unpack({fetch, ?VSN, Path}) -> {fetch, Path};
unpack({sync_complete, ?VSN}) -> sync_complete;
unpack({conflict_file, ?VSN, WorkPath, Path, Meta, Bin}) ->
    {conflict_file, WorkPath, Path, Meta, Bin};
unpack(Term) ->
    Term.
