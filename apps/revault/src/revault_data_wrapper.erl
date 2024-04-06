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
-export([manifest/0, manifest/1,
         send_file/4, send_multipart_file/6, send_deleted/2,
         send_conflict_file/5, send_conflict_multipart_file/7, fetch_file/1,
         sync_complete/0]).

-include("revault_data_wrapper.hrl").

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

%% @private send_multipart_file/6 is special in that it implies an ordering
%% between all calls for breaking down large file uploads.
%%
%% A new multipart transfer is defined with the `PartNum' value `1'. All
%% subsequent calls must get an incrementing `PartNum' in order, with no gap,
%% until `PartNum =:= PartTotal', which signals that the last part of the file
%% has been received and the write can be considered complete.
%%
%% This API is a choice that allows transferring sequentially to disk, or in
%% parallel in some S3 upload. In picking the lowest common denominator, we
%% expect sequential transfers, such that a file on disk can be continuously
%% appended.
%%
%% The `Hash' value sent is expected to be repeated every time, and is the hash
%% of the final transfer. This is because ReVault does not have any sort of
%% file locking mechanism, and expecting the same hash from beginning to end
%% allows us to detect if the source file has been modified during the
%% transfer, and ignore the result upon the final saving.
%%
%% TODO: this interface is different from the conflict file mechanism which uses
%% a decrementing counter. We might want to align the conflict file mechanism
%% at some point.
-spec send_multipart_file(Path, Vsn, Hash, PartNum, PartTotal, binary()) ->
        {file, ?VSN, Path, {Vsn, Hash}, PartNum, PartTotal, binary()}
           when Path :: file:filename(),
                Vsn :: revault_dirmon_tracker:stamp(),
                Hash :: revault_file:hash(),
                PartNum :: 1..10000,
                PartTotal :: 1..10000.
send_multipart_file(Path, Vsn, Hash, M, N, Bin) when M >= 1, M =< N ->
    {file, ?VSN, Path, {Vsn, Hash}, M, N, Bin}.

send_deleted(Path, Vsn) ->
    {deleted_file, ?VSN, Path, {Vsn, deleted}}.

send_conflict_file(WorkPath, Path, ConflictsLeft, Meta, Bin) ->
    {conflict_file, ?VSN, WorkPath, Path, ConflictsLeft, Meta, Bin}.

%% TODO: figure out if we need a way to work around conflict candidate files
%% having hashes modified from under us during the transfer
-spec send_conflict_multipart_file(WorkPath, Path, ConflictsLeft, Meta, PartNum, PartTotal, binary()) ->
        {conflict_multipart_file, ?VSN, WorkPath, Path, ConflictsLeft, Meta, PartNum, PartTotal, binary()}
           when WorkPath :: file:filename(),
                Path :: file:filename(),
                ConflictsLeft :: non_neg_integer(),
                Meta :: {revault_dirmon_tracker:stamp(),
                         revault_file:hash() | {conflict, [revault_file:hash()], revault_file:hash()}},
                PartNum :: 1..10000,
                PartTotal :: 1..10000.
send_conflict_multipart_file(WorkPath, Path, ConflictsLeft, Meta, PartNum, PartTotal, Bin) ->
    {conflict_multipart_file, ?VSN, WorkPath, Path, ConflictsLeft, Meta, PartNum, PartTotal, Bin}.

fetch_file(Path) ->
    {fetch, ?VSN, Path}.

sync_complete() ->
    {sync_complete, ?VSN}.

ok() -> {ok, ?VSN}.
error(R) -> {error, ?VSN, R}.

fork(Id, UUID) ->
    {Keep, Send} = revault_id:fork(Id),
    {Keep, {reply, {Send, UUID}}}.
