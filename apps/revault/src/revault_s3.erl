%% TODO: deal with error handling much, much better.
-module(revault_s3).
-export([hash/1, copy/2,
         tmp/0, tmp/1,
         find_hashes/2, find_hashes_uncached/2, size/1,
         multipart_init/3, multipart_update/6, multipart_final/4,
         %%% wrappers to file module; can never use a cache if we
         %%% want the cache module to safely use these.
         delete/1, consult/1, read_file/1, ensure_dir/1, is_regular/1,
         write_file/2, write_file/3, rename/2
        ]).

-define(MIN_PART_SIZE, 5242880). % 5 MiB, no limit on last part
-define(MAX_PART_SIZE, 5368709120). % 5 GiB
-define(MAX_PARTS, 10000).
-define(MAX_SIZE, 5497558138880). % 5 TiB

%% @doc takes a file and computes a hash for it as used to track changes
%% in ReVault. This hash is not guaranteed to be stable, but at this time
%% it is SHA256.
hash(Path) ->
    Res = aws_s3:head_object(client(), bucket(), Path,
                             #{<<"ChecksumMode">> => <<"ENABLED">>}),
    {ok, #{<<"ChecksumSHA256">> := HashB64}, _} = Res,
    base64:decode(HashB64).

copy(From, To) ->
    %% TODO: support copying with multipart for large files, with parallelism
    Source = filename:join([uri_string:quote(Part) || Part <- [bucket() | filename:split(From)]]),
    Res = aws_s3:copy_object(client(), bucket(), To,
                             #{<<"CopySource">> => Source}),
    handle_result(Res).

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
size(_Path) ->
    error(not_implemented).

-spec multipart_init(Path, PartsTotal, Hash) -> State when
    Path :: file:filename(),
    PartsTotal :: pos_integer(),
    Hash :: revault_file:hash(),
    State :: revault_file:multipart_state().
multipart_init(_Path, _PartsTotal, _Hash) ->
    error(not_implemented).

-spec multipart_update(State, Path, PartNum, PartsTotal, Hash, binary()) ->
    {ok, revault_file:multipart_state()} when
        State :: revault_file:multipart_state(),
        Path :: file:filename(),
        PartNum :: 1..10000,
        PartsTotal :: 1..10000,
        Hash :: revault_file:hash().
multipart_update({state, Path, _PartsSeen, PartsTotal, Hash, _Term},
                 Path, _PartNum, PartsTotal, Hash, _Bin) ->
    error(not_implemented).

-spec multipart_final(State, Path, PartsTotal, Hash) -> ok when
        State :: revault_file:multipart_state(),
    Path :: file:filename(),
    PartsTotal :: pos_integer(),
    Hash :: revault_file:hash().
multipart_final({state, Path, _PartsSeen, PartsTotal, Hash, _Term},
                Path, PartsTotal, Hash) ->
    error(not_implemented).

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
    Opts = [{recv_timeout, timer:minutes(10)},
            {connect_timeout, timer:seconds(30)},
            {checkout_timeout, timer:seconds(1)}],
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
translate_code(Code) -> Code.

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
