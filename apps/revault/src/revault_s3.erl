%% TODO: deal with error handling much, much better.
-module(revault_s3).
-export([hash/1, copy/2,
         tmp/0, tmp/1,
         find_hashes/2, find_hashes_uncached/2, size/1,
         read_range/3,
         multipart_init/3, multipart_update/6, multipart_final/4,
         %%% wrappers to file module; can never use a cache if we
         %%% want the cache module to safely use these.
         delete/1, consult/1, read_file/1, ensure_dir/1, is_regular/1,
         write_file/2, write_file/3, rename/2
        ]).

-define(MIN_PART_SIZE, 5242880). % 5 MiB, no limit on last part
-define(MAX_PART_SIZE, 5368709120). % 5 GiB
-define(MAX_PARTS, 10000).
%-define(MAX_SIZE, 5497558138880). % 5 TiB
%% Due to how hashes work, multipart size is limited to 5GiB. Beyond that size,
%% AWS S3 copy can't re-compute the hash and we can only work with a hash-of-hashes,
%% which will mess things up.
-define(MAX_SIZE, ?MAX_PART_SIZE).

%% @doc takes a file and computes a hash for it as used to track changes
%% in ReVault. This hash is not guaranteed to be stable, but at this time
%% it is SHA256.
hash(Path) ->
    Res = aws_s3:head_object(client(), bucket(), Path,
                             #{<<"ChecksumMode">> => <<"ENABLED">>}),
    {ok, #{<<"ChecksumSHA256">> := HashB64}, _} = Res,
    base64:decode(HashB64).

copy(From, To) ->
    handle_result(copy_raw(From, To)).

tmp() ->
    filename:join([s3_tmpdir(), randname()]).

tmp(Path) ->
    filename:join([s3_tmpdir(), Path]).

%% Naive, un-cached version
find_hashes_uncached(Dir, Pred) ->
    Files = list_all_files(Dir),
    NewList = lists:foldl(fun({File,_LastModified}, Acc) ->
        case Pred(File) of
            false ->
                Acc;
            true ->
                RelFile = revault_file:make_relative(Dir, File),
                Hash = hash(File),
                [{RelFile, Hash} | Acc]
        end
    end, [], Files),
    NewList.

%% Cached version
find_hashes(Dir, Pred) ->
    Files = list_all_files(Dir),
    revault_s3_cache:ensure_loaded(Dir),
    NewList = lists:foldl(fun({File,LastModified}, Acc) ->
        case Pred(File) of
            false ->
                Acc;
            true ->
                RelFile = revault_file:make_relative(Dir, File),
                case revault_s3_cache:hash(Dir, RelFile) of
                    {ok, {Hash, LastModified}} ->
                        [{RelFile, Hash} | Acc];
                    _R ->
                        Hash = hash(File),
                        revault_s3_cache:hash_store(Dir, RelFile, {Hash, LastModified}),
                        [{RelFile, Hash} | Acc]
                end
        end
    end, [], Files),
    revault_s3_cache:save(Dir),
    NewList.

-spec size(file:filename()) -> {ok, non_neg_integer()} | {error, term()}.
size(Path) ->
    BinPath = unicode:characters_to_binary(Path),
    Res = aws_s3:head_object(client(), bucket(), BinPath, #{}),
    maybe
        ok ?= handle_result(Res),
        {ok, #{<<"ContentLength">> := LenBin}, _} = Res,
        {ok, binary_to_integer(LenBin)}
    end.

%%%%%%%%%%%%%%%%%%%%%
%%% FILE WRAPPERS %%%
%%%%%%%%%%%%%%%%%%%%%

%%% Cannot use cache.


delete(Path) ->
    handle_result(aws_s3:delete_object(client(), bucket(), Path, #{})).

consult(Path) ->
    maybe
        {ok, Bin} ?= read_file(Path),
        {ok, Scanned} ?= scan_all(Bin),
        parse_all(Scanned)
    end.

read_file(Path) ->
    Res = aws_s3:get_object(client(), bucket(), Path),
    maybe
        ok ?= handle_result(Res),
        {ok, #{<<"Body">> := Contents}, _} = Res,
        {ok, Contents}
    end.

%% @doc Returns true if the path refers to a file, otherwise false.
-spec is_regular(file:filename_all()) -> boolean().
is_regular(Path) ->
    %% S3 returns a valid object for directories, but with a
    %% different content-type. We don't care here, whatever's good
    %% is good for us.
    Res = aws_s3:head_object(client(), bucket(), Path, #{}),
    case Res of
        {ok, #{<<"ContentType">> := <<"application/x-directory;", _/binary>>}, _} ->
            false;
        {ok, _, _} ->
            true;
        _ ->
            false
    end.

%% @doc This operation isn't required on S3 and is a no-op.
ensure_dir(_Path) ->
    ok.

write_file(Path, Data) ->
    %% TODO: deal with huge files by using multipart API
    Chk = base64:encode(revault_file:hash_bin(Data)),
    Input = #{<<"Body">> => Data,
              <<"ChecksumAlgorithm">> => <<"SHA256">>,
              <<"ChecksumSHA256">> => Chk},
    Opts = upload_opts(),
    Res = aws_s3:put_object(client(), bucket(), Path, Input, Opts),
    handle_result(Res).

write_file(Path, Data, Modes) ->
    Unsupported = lists:usort(Modes) -- [write,raw,binary,sync],
    case Unsupported of
        [] ->
            write_file(Path, Data);
        _ ->
            {error, badarg}
    end.

-spec read_range(Path, Offset, Bytes) -> {ok, binary()} | {error, term()} when
      Path :: file:filename(),
      Offset :: non_neg_integer(),
      Bytes :: pos_integer().
read_range(Path, Offset, Bytes) ->
    PathBin = unicode:characters_to_binary(Path),
    RangeStr = << "bytes=",
                  (integer_to_binary(Offset))/binary,
                  "-",
                  (integer_to_binary(Offset+(Bytes-1)))/binary >>,
    Res = aws_s3:get_object(client(), bucket(), PathBin, #{}, #{<<"Range">> => RangeStr}),
    maybe
        ok ?= handle_result(Res),
        {ok, #{<<"Body">> := Contents,
               <<"ContentLength">> := LengthBin}, _} = Res,
        %% AWS will give us data shorter than expected if we read after
        %% the end of a file, so catch that.
        case binary_to_integer(LengthBin) =:= Bytes of
            true -> {ok, Contents};
            false -> {error, invalid_range}
        end
    end.


-spec multipart_init(Path, PartsTotal, Hash) -> State when
    Path :: file:filename(),
    PartsTotal :: pos_integer(),
    Hash :: revault_file:hash(),
    State :: revault_file:multipart_state().
multipart_init(Path, PartsTotal, Hash) ->
    %% Multipart files don't carry their checksums in a way we need them to,
    %% so we do a cheat here by uploading them to a temporary location, then
    %% moving them via the S3 API. Under the covers, the S3 API does the copy
    %% as a single atomic operation, which re-computes the hash we need.
    Tmp = unicode:characters_to_binary(tmp()),
    {ok, #{<<"InitiateMultipartUploadResult">> :=
           #{<<"UploadId">> := UploadId}},
     {200, _Headers, _Ref}} =
       aws_s3:create_multipart_upload(
         client(), bucket(), Tmp,
         #{<<"ChecksumAlgorithm">> => <<"SHA256">>},
         upload_opts()
    ),
    {state, Path, 0, PartsTotal, Hash,
     {Tmp, UploadId, crypto:hash_init(sha256), []}}.

-spec multipart_update(State, Path, PartNum, PartsTotal, Hash, binary()) ->
    {ok, revault_file:multipart_state()} when
        State :: revault_file:multipart_state(),
        Path :: file:filename(),
        PartNum :: 1..10000,
        PartsTotal :: 1..10000,
        Hash :: revault_file:hash().
multipart_update({state, Path, _PartsSeen, PartsTotal, Hash,
                  {Tmp, UploadId, RollingHash, PartsAcc}},
                 Path, PartNum, PartsTotal, Hash, Bin) ->
    %% This check assumes all parts are equal (excluding any trailer,
    %% which is risky), but if the uploaded file would be bigger
    %% than the max size, it aborts the upload and generates an error.
    ProjectedSize = PartsTotal-1 * byte_size(Bin),
    case ProjectedSize >= ?MAX_SIZE of
        true ->
            aws_s3:abort_multipart_upload(
                client(), bucket(), Tmp, #{<<"UploadId">> => UploadId}, []
            ),
            error({file_too_large, ProjectedSize});
        false ->
            ok
    end,
    PartHash = revault_file:hash_bin(Bin),
    Chk = base64:encode(PartHash),
    NewRollingHash = crypto:hash_update(RollingHash, Bin),
    Res = aws_s3:upload_part(
        client(), bucket(), Tmp,
        #{<<"Body">> => Bin,
          <<"ChecksumAlgorithm">> => <<"SHA256">>,
          <<"ChecksumSHA256">> => Chk,
          <<"PartNumber">> => integer_to_binary(PartNum),
          <<"UploadId">> => UploadId
         },
        upload_opts()
    ),
    maybe
        ok ?= handle_result(Res),
        {ok, #{<<"ETag">> := PartETag, <<"ChecksumSHA256">> := Chk}, _} = Res,
        {ok, {state, Path, PartNum, PartsTotal, Hash,
              {Tmp, UploadId, NewRollingHash,
               [{PartNum, {PartHash, PartETag}} | PartsAcc]}}}
    end.

-spec multipart_final(State, Path, PartsTotal, Hash) -> ok when
        State :: revault_file:multipart_state(),
    Path :: file:filename(),
    PartsTotal :: pos_integer(),
    Hash :: revault_file:hash().
multipart_final({state, Path, _PartsSeen, PartsTotal, Hash,
                  {Tmp, UploadId, RollingHash, PartsAcc}},
                Path, PartsTotal, Hash) ->
    %% Compute our own final hash and the final checksum
    case  crypto:hash_final(RollingHash) of
        Hash -> ok;
        _ -> error(invalid_hash)
    end,
    Chk = base64:encode(Hash),
    %% S3 multipart upload does a checksum of checksums with a -N suffix.
    %% We'll move the upload to get the final hash, but we still want to do
    %% a partial check.
    MultipartHash = revault_file:hash_bin(
        << <<PartHash/binary>> || {_, {PartHash, _}} <- lists:reverse(PartsAcc) >>
    ),
    MultipartChk = << (base64:encode(MultipartHash))/binary,
                      "-", (integer_to_binary(length(PartsAcc)))/binary>>,
    %% finalize the upload
    PartsChecks = #{<<"Part">> =>
        [#{<<"PartNumber">> => integer_to_binary(PartNum),
           <<"ETag">> => PartETag,
           <<"ChecksumSHA256">> => base64:encode(PartHash)}
         || {PartNum, {PartHash, PartETag}} <- lists:reverse(PartsAcc)]
    },
    ResFinalize = aws_s3:complete_multipart_upload(
        client(), bucket(), Tmp,
        #{<<"UploadId">> => UploadId, <<"CompleteMultipartUpload">> => PartsChecks},
        upload_opts()
    ),
    maybe
        ok ?= handle_result(ResFinalize),
        {ok, #{<<"CompleteMultipartUploadResult">> :=
               #{<<"ChecksumSHA256">> := MultipartChk}},
         _} = ResFinalize,
        CopyRes = copy_raw(Tmp, unicode:characters_to_binary(Path)),
        ok ?= handle_result(CopyRes),
        {ok, #{<<"CopyObjectResult">> := #{<<"ChecksumSHA256">> := Chk}}, _} = CopyRes,
        handle_result(aws_s3:delete_object(client(), bucket(), Tmp, #{}))
    end.

%% @doc No such atomic thing, so fake it with a copy+delete as if
%% we were crossing filesystem boundaries
rename(From, To) ->
    maybe
        ok ?= copy(From, To),
        handle_result(aws_s3:delete_object(client(), bucket(), From, #{}))
    end.

%%%%%%%%%%%%%%%
%%% PRIVATE %%%
%%%%%%%%%%%%%%%
client() -> revault_s3_serv:get_client().

bucket() -> application:get_env(revault, bucket, undefined).

-spec handle_result(term()) -> ok | {error, term()}.
handle_result({ok, _, _}) ->
    ok;
handle_result({error, #{<<"Error">> := #{<<"Code">> := Code}}, _}) ->
    {error, translate_code(Code)};
handle_result({error, {404, _Headers}}) ->
    {error, enoent};
handle_result({error, timeout}) ->
    {error, timeout};
handle_result(_Unknown) ->
    %% TODO: more graceful handling
    io:format("unknown s3 result: ~p~n", [_Unknown]),
    {error, badarg}.

translate_code(<<"NoSuchKey">>) -> enoent;
translate_code(<<"InvalidRange">>) -> invalid_range;
translate_code(Code) -> Code.

copy_raw(From, To) ->
    Source = filename:join([uri_string:quote(Part) || Part <- [bucket() | filename:split(From)]]),
    aws_s3:copy_object(client(), bucket(), To, #{<<"CopySource">> => Source}).

scan_all(Bin) ->
    Str = unicode:characters_to_list([Bin, " "]),
    try scan_all([], Str, 1) of
        List when is_list(List) -> {ok, List}
    catch
        error:Reason -> {error, Reason}
    end.

scan_all(Cont, Str, Ln) ->
    %% Do some ugly stuff to maintain line counts equivalence with
    %% file:consult/1 even though we don't work with lines.
    Lns = length(string:split(Str, "\n", all))-1,
    case erl_scan:tokens(Cont, Str, 0) of
        {done, {ok, Res, _}, ""} ->
            [Res];
        {done, {ok, Res, _}, Next} ->
            LnsLeft = length(string:split(Next, "\n", all))-1,
            [Res| scan_all([],Next, Ln+(Lns-LnsLeft))];
        {more, _Cont} ->
            case re:run(Str, "^\\s+$") of
                nomatch -> error({Ln, erl_parse, ["syntax error before: ", ""]});
                _ -> []
            end
    end.

parse_all(L) ->
    try
        [erl_parse:normalise(Exp) ||
         X <- L,
         {ok, [Exp]} <- [erl_parse:parse_exprs(X)]]
    of
        Normalised -> {ok, Normalised}
    catch
        error:_ -> {error, {0, erl_parse, "bad_term"}}
    end.

s3_tmpdir() ->
    Dir = application:get_env(revault, s3_tmpdir, ".tmp"),
    %% S3 really does not like an absolute path here as it will mess
    %% with copy paths, so bail out if we find that happening.
    case string:prefix(Dir, "/") of
        nomatch -> Dir;
        _ -> error(absolute_s3_tmpdir)
    end.

randname() ->
    float_to_list(rand:uniform()).

list_all_files(Dir) ->
    list_all_files(Dir, undefined).

list_all_files(Dir, Continuation) ->
    BaseOpts = case Continuation of
        undefined -> #{};
        _ -> #{<<"continuation-token">> => Continuation}
    end,
    Res = aws_s3:list_objects_v2(client(), bucket(),
                                 BaseOpts#{<<"prefix">> => <<Dir/binary, "/">>}, #{}),
    case Res of
        {ok, Map=#{<<"ListBucketResult">> := #{<<"Contents">> := Contents}}, _} ->
            Files = if is_list(Contents) ->
                           [fetch_content(C) || C <- Contents];
                       is_map(Contents) ->
                           [fetch_content(Contents)]
                    end,
            case Map of
                #{<<"IsTruncated">> := <<"true">>, <<"NextContinuationToken">> := Next} ->
                    Files ++ list_all_files(Dir, Next);
                _ ->
                    Files
            end;
        {ok, #{<<"ListBucketResult">> := #{<<"KeyCount">> := <<"0">>}}, _} ->
            []
    end.

fetch_content(#{<<"Key">> := Path, <<"LastModified">> := Stamp}) ->
    {Path, Stamp}.

%% @private standard options the AWS client expects to lengthen how long
%% we have to upload parts or files.
upload_opts() ->
    [{recv_timeout, timer:minutes(10)},
     {connect_timeout, timer:seconds(30)},
     {checkout_timeout, timer:seconds(1)}].
