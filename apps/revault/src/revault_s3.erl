%% TODO: pick and normalize on a path format for s3 entries
%% TODO: deal with error handling much, much better.
-module(revault_s3).
-export([hash/1, copy/2,
         tmp/0, tmp/1,
         find_hashes/2, find_hashes_uncached/2,
         %%% wrappers to file module; can never use a cache if we
         %%% want the cache module to safely use these.
         delete/1, consult/1, read_file/1,
         write_file/2, write_file/3, rename/2
        ]).

%% @doc takes a file and computes a hash for it as used to track changes
%% in ReVault. This hash is not guaranteed to be stable, but at this time
%% it is SHA256.
hash(Path) ->
    %% TODO: support the cached path hash check
    Res = aws_s3:head_object(client(), bucket(), Path,
                             #{<<"ChecksumMode">> => <<"ENABLED">>}),
    {ok, #{<<"ChecksumSHA256">> := HashB64}, _} = Res,
    base64:decode(HashB64).

copy(From, To) ->
    Source = filename:join(bucket(), From),
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

%%%%%%%%%%%%%%%%%%%%%
%%% FILE WRAPPERS %%%
%%%%%%%%%%%%%%%%%%%%%

%%% Cannot use cache.


delete(Path) ->
    handle_result(aws_s3:delete_object(client(), bucket(), Path, #{})).

consult(Path) ->
    maybe
        {ok, Bin} ?= read_file(Path),
        %% TODO: handle parse errors
        {ok, parse_all(scan_all(Bin))}
    end.

read_file(Path) ->
    Res = aws_s3:get_object(client(), bucket(), Path),
    maybe
        ok ?= handle_result(Res),
        {ok, #{<<"Body">> := Contents}, _} = Res,
        {ok, Contents}
    end.

write_file(Path, Data) ->
    Chk = base64:encode(revault_file:hash_bin(Data)),
    Res = aws_s3:put_object(client(), bucket(), Path,
                            #{<<"Body">> => Data,
                              <<"ChecksumAlgorithm">> => <<"SHA256">>,
                              <<"ChecksumSHA256">> => Chk}),
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
handle_result(_Unknown) ->
    %% TODO: more graceful handling
    {error, badarg}.

translate_code(<<"NoSuchKey">>) -> enoent;
translate_code(Code) -> Code.

scan_all(Bin) ->
    Str = unicode:characters_to_list([Bin, " "]),
    scan_all([], Str).

scan_all(Cont, Str) ->
    case erl_scan:tokens(Cont, Str, 0) of
        {done, {ok, Res, _}, ""} ->
            [Res];
        {done, {ok,Res,_}, Next} ->
            [Res| scan_all([],Next)];
        {more, _Cont} ->
            case re:run(Str, "^\\s+$") of
                nomatch -> error(incomplete);
                _ -> []
            end
    end.

parse_all(L) ->
    [erl_parse:normalise(Exp) ||
     X <- L,
     {ok, [Exp]} <- [erl_parse:parse_exprs(X)]].

s3_tmpdir() ->
    application:get_env(revault, s3_tmpdir, "/.tmp").

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
    {ok, Map=#{<<"ListBucketResult">> := #{<<"Contents">> := Contents}}, _} = Res,
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
    end.

fetch_content(#{<<"Key">> := Path, <<"LastModified">> := Stamp}) ->
    {Path, Stamp}.
