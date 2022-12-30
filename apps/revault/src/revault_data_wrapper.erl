%%% @doc Data wrapper for revault's FSMs, dealing with creating a data
%%% representation for common stateful operations.
%%%
%%% One important thing to note is that while we expect the server-side
%%% (with an already-created ID) to exist, we can't make that assumption
%%% from the client side if it does not exist yet, since booting it
%%% through `revault_dirmon_tracker' requires passing in the seed ID.
%%%
%%% This implies that the ID will be stored somewhere stateful, but the
%%% protocol here does not need to know where or how.
-module(revault_data_wrapper).
-export([peer/1, peer/2, new/0, ask/0, ok/0, error/1, fork/2]).
-export([manifest/0, manifest/1, send_file/4, send_deleted/2,
         send_conflict_file/5, fetch_file/1,
         sync_complete/0]).
-define(VSN, 1).

peer(Remote) ->
    {peer, ?VSN, Remote}.

peer(Remote, UUID) ->
    {peer, ?VSN, Remote, UUID}.

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

send_deleted(Path, Vsn) ->
    {deleted_file, ?VSN, Path, {Vsn, deleted}}.

send_conflict_file(WorkPath, Path, ConflictsLeft, Meta, Bin) ->
    {conflict_file, ?VSN, WorkPath, Path, ConflictsLeft, Meta, Bin}.

fetch_file(Path) ->
    {fetch, ?VSN, Path}.

sync_complete() ->
    {sync_complete, ?VSN}.

ok() -> {ok, ?VSN}.
error(R) -> {error, ?VSN, R}.

fork(Id, UUID) ->
    {Keep, Send} = revault_id:fork(Id),
    {Keep, {reply, {Send, UUID}}}.
