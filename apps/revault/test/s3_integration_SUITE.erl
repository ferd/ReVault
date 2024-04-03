-module(s3_integration_SUITE).
-compile(export_all).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() -> [{group, api},
          {group, abstraction},
          {group, cache}].

groups() ->
    [{api, [sequence], [list_objects_empty, crud_object, rename_raw, pagination,
                        multipart_upload, get_object_range]},
     {abstraction, [sequence], [read_write_delete, hasht, copy, rename,
                                find_hashes, consult, is_regular,
                                multipart, read_range]},
     {cache, [sequence], [find_hashes_cached]}
    ].

init_per_suite(Config) ->
    case os:getenv("REVAULT_S3_INTEGRATION_SUITE") of
        "true" -> setup_aws(Config);
        _ -> {skip, "REVAULT_S3_INTEGRATION_SUITE != \"true\""}
    end.

end_per_suite(Config) ->
    Apps = proplists:get_value(apps, Config, []),
    [application:stop(App) || App <- lists:reverse(Apps)],
    ok.

init_per_group(abstraction, Config) ->
    InitBucket = application:get_env(revault, bucket, undefined),
    application:set_env(revault, bucket, ?config(bucket, Config)),
    {ok, Pid} = revault_s3_serv:start_link(
        ?config(role_arn, Config),
        ?config(region, Config),
        ?config(role_session_name, Config)
    ),
    unlink(Pid),
    [{init_bucket, InitBucket}, {serv, Pid}
     |Config];
init_per_group(cache, Config0) ->
    {ok, Apps} = application:ensure_all_started(gproc),
    Config = init_per_group(abstraction, Config0),
    CacheDir = ?config(bucket_cache_dir, Config),
    Dir = ?config(bucket_dir, Config),
    {ok, Pid} = revault_s3_cache:start_link(CacheDir, Dir),
    unlink(Pid),
    [{cache_pid, Pid}, {cache_apps, Apps} | Config];
init_per_group(_, Config) ->
    Config.

end_per_group(abstraction, Config) ->
    gen_server:stop(?config(serv, Config)),
    application:set_env(revault, bucket, ?config(init_bucket, Config)),
    Config;
end_per_group(cache, Config0) ->
    gen_server:stop(?config(cache_pid, Config0)),
    [application:stop(App) || App <- lists:reverse(?config(cache_apps, Config0))],
    Config = end_per_group(abstraction, Config0),
    Config;
end_per_group(_, Config) ->
    Config.

%%%%%%%%%%%%%%%%%
%%% API GROUP %%%
%%%%%%%%%%%%%%%%%
list_objects_empty() ->
    [{doc, "make sure the test bucket is empty before running tests"}].
list_objects_empty(Config) ->
    Dir = ?config(bucket_dir, Config),
    Res = aws_s3:list_objects_v2(?config(aws_client, Config), ?config(bucket, Config)),
    %% we got a listing
    ?assertMatch({ok, #{<<"ListBucketResult">> := #{}}, _Http}, Res),
    {ok, #{<<"ListBucketResult">> := Listing}, _Http} = Res,
    case Listing of
        #{<<"Contents">> := FileMap = #{}} -> % single entry
            assert_dir_empty(Dir, [FileMap]);
        #{<<"Contents">> := FileMaps = [_|_]} -> % many entries
            assert_dir_empty(Dir, FileMaps);
        #{} -> % empty
            ok
    end,
    ok.

crud_object() ->
    [{doc, "objects can be created, read, updated, and deleted."}].
crud_object(Config) ->
    Client = ?config(aws_client, Config),
    Bucket = ?config(bucket, Config),
    Dir = ?config(bucket_dir, Config),
    Key = filename:join([Dir, "crud_object"]),
    Body = <<"v1">>,
    Chk = hash(Body),
    NewBody = <<"v2">>,
    NewChk = hash(NewBody),
    %% Create, with SHA256
    ?assertMatch({ok, #{<<"ChecksumSHA256">> := Chk}, _Http},
                 aws_s3:put_object(Client, Bucket, Key,
                                   #{<<"Body">> => Body,
                                     <<"ChecksumAlgorithm">> => <<"SHA256">>,
                                     <<"ChecksumSHA256">> => Chk})),
    %% Create, with bad SHA256
    ?assertMatch({error, #{<<"Error">> := #{<<"Code">> := <<"BadDigest">>}}, _Http},
                 aws_s3:put_object(Client, Bucket, Key,
                                   #{<<"Body">> => <<"fakebody">>,
                                     <<"ChecksumAlgorithm">> => <<"SHA256">>,
                                     <<"ChecksumSHA256">> => Chk})),
    %% Update
    ?assertMatch({ok, #{<<"ChecksumSHA256">> := NewChk}, _Http},
                 aws_s3:put_object(Client, Bucket, Key,
                                   #{<<"Body">> => NewBody,
                                     <<"ChecksumAlgorithm">> => <<"SHA256">>,
                                     <<"ChecksumSHA256">> => NewChk})),
    %% Read
    ?assertMatch({ok, #{<<"Body">> := NewBody}, _Http},
                 aws_s3:get_object(Client, Bucket, Key)),
    %% Get Hash and size
    ?assertMatch({ok, #{<<"ChecksumSHA256">> := NewChk,
                        <<"ContentLength">> := <<"2">>}, _Http},
                 aws_s3:head_object(Client, Bucket, Key,
                                    #{<<"ChecksumMode">> => <<"ENABLED">>})),
    %% Delete
    ?assertMatch({ok, #{}, _Http},
                 aws_s3:delete_object(Client, Bucket, Key, #{})),
    ok.

rename_raw() ->
    [{doc, "Simulate a rename operation."}].
rename_raw(Config) ->
    Client = ?config(aws_client, Config),
    Bucket = ?config(bucket, Config),
    Dir = ?config(bucket_dir, Config),
    KeySrc = filename:join([Dir, "rename-orig"]),
    KeyDest = filename:join([Dir, "rename-target"]),
    Body = <<"v1">>,
    Chk = hash(Body),
    %% Create, with SHA256
    ?assertMatch({ok, #{<<"ChecksumSHA256">> := Chk}, _Http},
                 aws_s3:put_object(Client, Bucket, KeySrc,
                                   #{<<"Body">> => Body,
                                     <<"ChecksumAlgorithm">> => <<"SHA256">>,
                                     <<"ChecksumSHA256">> => Chk})),
    %% Copy+Delete
    ?assertMatch({ok, #{<<"CopyObjectResult">> := #{<<"ChecksumSHA256">> := Chk}}, _Http},
                 aws_s3:copy_object(Client, Bucket, KeyDest,
                                    #{<<"CopySource">> => filename:join(Bucket, KeySrc)})),
    ?assertMatch({ok, #{}, _Http},
                 aws_s3:delete_object(Client, Bucket, KeySrc, #{})),
    %% Read Mode
    ?assertMatch({ok, #{<<"Body">> := Body}, _Http},
                 aws_s3:get_object(Client, Bucket, KeyDest)),
    ?assertMatch({ok, #{<<"ChecksumSHA256">> := Chk}, _Http},
                 aws_s3:head_object(Client, Bucket, KeyDest,
                                    #{<<"ChecksumMode">> => <<"ENABLED">>})),
    %% Delete
    ?assertMatch({ok, #{}, _Http},
                 aws_s3:delete_object(Client, Bucket, KeyDest, #{})),
    ok.

pagination() ->
    [{doc, "make sure the listing mechanism can deal with limits"}].
pagination(Config) ->
    Client = ?config(aws_client, Config),
    Bucket = ?config(bucket, Config),
    Dir = ?config(bucket_dir, Config),
    Key = filename:join([Dir, "p"]),
    PageSize = 2,
    Objects = PageSize+1,
    [aws_s3:put_object(Client, Bucket, <<Key/binary, (integer_to_binary(N))/binary>>,
                       #{<<"Body">> => <<".">>,
                         <<"ChecksumAlgorithm">> => <<"SHA256">>,
                         <<"ChecksumSHA256">> => hash(<<".">>)
                        })
     || N <- lists:seq(1, Objects)],
    %% Scan with pages
    {ok, #{<<"ListBucketResult">> := #{
      <<"Contents">> := [_,_],
      <<"IsTruncated">> := <<"true">>,
      <<"KeyCount">> := <<"2">>, <<"MaxKeys">> := <<"2">>,
      <<"NextContinuationToken">> := NextToken
    }}, _} = aws_s3:list_objects_v2(?config(aws_client, Config), ?config(bucket, Config),
                                   #{<<"max-keys">> => PageSize, <<"prefix">> => Dir}, #{}),
    {ok, #{<<"ListBucketResult">> := #{
      <<"Contents">> := #{},
      <<"IsTruncated">> := <<"false">>,
      <<"KeyCount">> := <<"1">>, <<"MaxKeys">> := <<"2">>
    }}, _} = aws_s3:list_objects_v2(?config(aws_client, Config), ?config(bucket, Config),
                                   #{<<"max-keys">> => PageSize, <<"prefix">> => Dir,
                                     <<"continuation-token">> => NextToken}, #{}),
    %% Clean up
    [aws_s3:delete_object(Client, Bucket, <<Key/binary, (integer_to_binary(N))/binary>>, #{})
     || N <- lists:seq(1, Objects)],
    ok.

multipart_upload() ->
    [{doc, "Test the multipart functionality basics"}].
multipart_upload(Config) ->
    Client = ?config(aws_client, Config),
    Bucket = ?config(bucket, Config),
    Dir = ?config(bucket_dir, Config),
    Key = filename:join([Dir, "multiparted"]),
    KeyCopy = filename:join([Dir, "multiparted-copy"]),
    %% Minimum multipart size is 5MiB
    MinSize = 5*1024*1024,
    P1 = <<1:(MinSize*8)>>,
    P2 = <<2:(MinSize*8)>>,
    P3 = <<3>>, % can be smaller
    FullFile = <<P1/binary, P2/binary, P3/binary>>,
    FullHash = hash(FullFile),
    Opts = [{recv_timeout, timer:minutes(1)},
            {connect_timeout, timer:seconds(30)},
            {checkout_timeout, timer:seconds(1)}],
    %% Prepare the multipart upload
    {ok, #{<<"InitiateMultipartUploadResult">> := #{<<"UploadId">> := UploadId}},
     {200, _Headers, _Ref}} =
       aws_s3:create_multipart_upload(Client, Bucket, Key,
                                      #{<<"ChecksumAlgorithm">> => <<"SHA256">>}, Opts),
    %% Upload the file
    {ok, #{<<"ETag">> := P1ETag,
           <<"ChecksumSHA256">> := _},
     {200, _, _}} =
      aws_s3:upload_part(Client, Bucket, Key,
                         #{<<"Body">> => P1,
                           <<"ChecksumAlgorithm">> => <<"SHA256">>,
                           <<"ChecksumSHA256">> => hash(P1),
                           <<"PartNumber">> => <<"1">>,
                           <<"UploadId">> => UploadId
                        },
                        Opts),
    {ok, #{<<"ETag">> := P2ETag,
           <<"ChecksumSHA256">> := _},
     {200, _, _}} =
      aws_s3:upload_part(Client, Bucket, Key,
                         #{<<"Body">> => P2,
                           <<"ChecksumAlgorithm">> => <<"SHA256">>,
                           <<"ChecksumSHA256">> => hash(P2),
                           <<"PartNumber">> => <<"2">>,
                           <<"UploadId">> => UploadId
                        },
                        Opts),
    {ok, #{<<"ETag">> := P3ETag,
           <<"ChecksumSHA256">> := _},
     {200, _, _}} =
      aws_s3:upload_part(Client, Bucket, Key,
                         #{<<"Body">> => P3,
                           <<"ChecksumAlgorithm">> => <<"SHA256">>,
                           <<"ChecksumSHA256">> => hash(P3),
                           <<"PartNumber">> => <<"3">>,
                           <<"UploadId">> => UploadId
                        },
                        Opts),
    %% Finish the upload
    ct:pal("Full Hash: ~p (~p)", [FullHash, {hash(P1), hash(P2), hash(P3)}]),
    Res = aws_s3:complete_multipart_upload(
        Client, Bucket, Key,
        #{<<"UploadId">> => UploadId,
          <<"CompleteMultipartUpload">> =>
           #{<<"Part">> => [
                #{<<"PartNumber">> => <<"1">>, <<"ETag">> => P1ETag, <<"ChecksumSHA256">> => hash(P1)},
                #{<<"PartNumber">> => <<"2">>, <<"ETag">> => P2ETag, <<"ChecksumSHA256">> => hash(P2)},
                #{<<"PartNumber">> => <<"3">>, <<"ETag">> => P3ETag, <<"ChecksumSHA256">> => hash(P3)}
           ]}
        },
        Opts),
    %% Read the hash; it is a composite one we can't use.
    MultiPartHash = <<(hash(<<(crypto:hash(sha256, P1))/binary,
                              (crypto:hash(sha256, P2))/binary,
                              (crypto:hash(sha256, P3))/binary>>))/binary, "-3">>,
    ct:pal("Multipart Hash: ~p", [MultiPartHash]),
    {ok,#{<<"CompleteMultipartUploadResult">> := #{<<"ChecksumSHA256">> := MultiPartHash}},
     {200, _, _}} = Res,
    {ok, #{<<"ChecksumSHA256">> := MultiPartHash},
     {200, _}} = aws_s3:head_object(Client, Bucket, Key,
                                    #{<<"ChecksumMode">> => <<"ENABLED">>}),
    %% Copy the object to re-compute the full hash (works under 5Gb)
    aws_s3:copy_object(Client, Bucket, KeyCopy, #{<<"CopySource">> => filename:join(Bucket, Key)}),
    {ok, #{<<"ChecksumSHA256">> := FullHash},
     {200, _}} = aws_s3:head_object(Client, Bucket, KeyCopy,
                                    #{<<"ChecksumMode">> => <<"ENABLED">>}),
    %% Clean up
    aws_s3:delete_object(Client, Bucket, Key, #{}),
    aws_s3:delete_object(Client, Bucket, KeyCopy, #{}),
    ok.

get_object_range() ->
    [{doc, "Range queries can be submitted to read subset of objects"}].
get_object_range(Config) ->
    Client = ?config(aws_client, Config),
    Bucket = ?config(bucket, Config),
    Dir = ?config(bucket_dir, Config),
    Key = filename:join([Dir, "crud_object"]),
    Body = <<"0123456789abcdef">>,
    Chk = hash(Body),
    %% Create, with SHA256
    ?assertMatch({ok, #{<<"ChecksumSHA256">> := Chk}, _Http},
                 aws_s3:put_object(Client, Bucket, Key,
                                   #{<<"Body">> => Body,
                                     <<"ChecksumAlgorithm">> => <<"SHA256">>,
                                     <<"ChecksumSHA256">> => Chk})),
    %% Read, range being firstbyte-lastbyte
    ?assertMatch({ok, #{<<"Body">> := <<"0">>}, _Http},
                 aws_s3:get_object(Client, Bucket, Key, #{},
                                   #{<<"Range">> => <<"bytes=0-0">>})),
    ?assertMatch({ok, #{<<"Body">> := <<"01">>}, _Http},
                 aws_s3:get_object(Client, Bucket, Key, #{},
                                   #{<<"Range">> => <<"bytes=0-1">>})),
    ?assertMatch({ok, #{<<"Body">> := <<"1">>}, _Http},
                 aws_s3:get_object(Client, Bucket, Key, #{},
                                   #{<<"Range">> => <<"bytes=1-1">>})),
    ?assertMatch({ok, #{<<"Body">> := <<"9abcd">>}, _Http},
                 aws_s3:get_object(Client, Bucket, Key, #{},
                                   #{<<"Range">> => <<"bytes=9-13">>})),
    %% It ignores incomplete endings so long as the start position is valid
    ?assertMatch({ok, #{<<"Body">> := <<"9abcdef">>,
                        <<"ContentLength">> := <<"7">>}, _Http},
                 aws_s3:get_object(Client, Bucket, Key, #{},
                                   #{<<"Range">> => <<"bytes=9-130">>})),
    ?assertMatch({error, #{<<"Error">> := #{<<"Code">> := <<"InvalidRange">>}}, _Http},
                 aws_s3:get_object(Client, Bucket, Key, #{},
                                   #{<<"Range">> => <<"bytes=19-130">>})),
    %% Delete
    ?assertMatch({ok, #{}, _Http},
                 aws_s3:delete_object(Client, Bucket, Key, #{})),
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%
%%% ABSTRACTION GROUP %%%
%%%%%%%%%%%%%%%%%%%%%%%%%
read_write_delete() ->
    [{doc, "Test read_file/1, write_file/2-3, and delete/1 calls"}].
read_write_delete(Config) ->
    Dir = ?config(bucket_dir, Config),
    Path = filename:join([Dir, "subdir", "read_write.txt"]),
    ?assertEqual({error, enoent}, revault_s3:read_file(Path)),
    ?assertEqual(ok, revault_s3:write_file(Path, <<"a">>)),
    ?assertEqual({ok, <<"a">>}, revault_s3:read_file(Path)),
    ?assertEqual(ok, revault_s3:write_file(Path, <<"b">>, [sync])),
    ?assertEqual({ok, <<"b">>}, revault_s3:read_file(Path)),
    ?assertEqual(ok, revault_s3:delete(Path)),
    ?assertEqual({error, enoent}, revault_s3:read_file(Path)),
    ok.

hasht() ->
    [{doc, "Test the hash-fetching functionality"}].
hasht(Config) ->
    Dir = ?config(bucket_dir, Config),
    Path = filename:join([Dir, "subdir", "hash.txt"]),
    % ?assertEqual({error, enoent}, revault_s3:hash(Path)), % unsupported
    ?assertEqual(ok, revault_s3:write_file(Path, <<"a">>)),
    ?assertEqual(revault_file:hash_bin(<<"a">>),
                 revault_s3:hash(Path)),
    ?assertEqual(ok, revault_s3:delete(Path)),
    ok.

copy() ->
    [{doc, "Test the file copying functionality"}].
copy(Config) ->
    Dir = ?config(bucket_dir, Config),
    Src = filename:join([Dir, "orig.txt"]),
    Dst = filename:join([Dir, "new.txt"]),
    ?assertEqual(ok, revault_s3:write_file(Src, <<"a">>)),
    ?assertEqual(ok, revault_s3:copy(Src, Dst)),
    ?assertEqual(revault_s3:hash(Src),
                 revault_s3:hash(Dst)),
    ?assertEqual(ok, revault_s3:delete(Src)),
    ?assertEqual(ok, revault_s3:delete(Dst)),
    ok.

rename() ->
    [{doc, "Test the file renaming functionality"}].
rename(Config) ->
    Dir = ?config(bucket_dir, Config),
    Src = filename:join([Dir, "orig.txt"]),
    Dst = filename:join([Dir, "new.txt"]),
    ?assertEqual(ok, revault_s3:write_file(Src, <<"a">>)),
    ?assertEqual(ok, revault_s3:rename(Src, Dst)),
    ?assertEqual({error, enoent}, revault_s3:read_file(Src)),
    ?assertMatch({ok, _}, revault_s3:read_file(Dst)),
    ?assertEqual(ok, revault_s3:delete(Dst)),
    ok.

find_hashes() ->
    [{doc, "exercise the hash-fetching functionality"}].
find_hashes(Config) ->
    Dir = ?config(bucket_dir, Config),
    PathA = filename:join([Dir, "subdir", "hash.txt"]),
    PathB = filename:join([Dir, "hash.txt"]),
    PathC = filename:join([Dir, "hash.ext"]),
    ?assertEqual(ok, revault_s3:write_file(PathA, <<"a">>)),
    ?assertEqual(ok, revault_s3:write_file(PathB, <<"b">>)),
    ?assertEqual(ok, revault_s3:write_file(PathC, <<"c">>)),
    ?assertEqual([{<<"subdir/hash.txt">>, revault_file:hash_bin(<<"a">>)},
                  {<<"hash.txt">>, revault_file:hash_bin(<<"b">>)},
                  {<<"hash.ext">>, revault_file:hash_bin(<<"c">>)}],
                 lists:reverse(lists:sort(
                    revault_s3:find_hashes_uncached(Dir, fun(_) -> true end)
                 ))),
    ?assertEqual(ok, revault_s3:delete(PathA)),
    ?assertEqual(ok, revault_s3:delete(PathB)),
    ?assertEqual(ok, revault_s3:delete(PathC)),
    ok.

consult() ->
    [{doc, "do a basic check on file consulting"}].
consult(Config) ->
    Dir = ?config(bucket_dir, Config),
    Path = filename:join([Dir, "consult"]),
    Str = <<"#{a=>b}. atom. [\"list\"].">>,
    Term = [#{a=>b}, atom, ["list"]],
    ?assertEqual(ok, revault_s3:write_file(Path, Str)),
    ?assertEqual({ok, Term}, revault_s3:consult(Path)),
    ?assertEqual(ok, revault_s3:delete(Path)),
    ok.

is_regular() ->
    [{doc, "Test the file-identifying functionality"}].
is_regular(Config) ->
    Dir = ?config(bucket_dir, Config),
    Path = filename:join([Dir, "subdir", "hash.txt"]),
    ?assertEqual(ok, revault_s3:write_file(Path, <<"a">>)),
    ?assertNot(revault_s3:is_regular(Dir)),
    ?assertNot(revault_s3:is_regular(filename:join([Dir, "subdir"]))),
    ?assert(revault_s3:is_regular(Path)),
    ?assertNot(revault_s3:is_regular(filename:join([Dir, "subdir", "fakefile"]))),
    ?assertNot(revault_s3:is_regular(filename:join([Dir, "fakedir"]))),
    ?assertEqual(ok, revault_s3:delete(Path)),
    ok.

multipart() ->
    [{doc, "Test the multipart upload functionality"}].
multipart(Config) ->
    Dir = ?config(bucket_dir, Config),
    Path = filename:join([Dir, "mpart"]),

    WidthBytes = 1024*1024*5,
    WidthBits = 8*WidthBytes,
    Parts = 11,
    Bin = <<0:WidthBits, 1:WidthBits, 2:WidthBits, 3:WidthBits, 4:WidthBits,
            5:WidthBits, 6:WidthBits, 7:WidthBits, 8:WidthBits, 9:WidthBits, 10>>,
    Hash = revault_file:hash_bin(Bin),
    {_, State} = lists:foldl(
        fun(Part, {N,S}) ->
            {ok, NewS} = revault_s3:multipart_update(S, Path, N, Parts, Hash, Part),
            {N+1, NewS}
        end,
        {1, revault_s3:multipart_init(Path, Parts, Hash)},
        [<<N:WidthBits>> || N <- lists:seq(0,Parts-2)]++[<<10>>]
    ),
    ok = revault_s3:multipart_final(State, Path, Parts, Hash),
    ?assertEqual({ok, Bin}, revault_s3:read_file(Path)),
    ?assertEqual(ok, revault_s3:delete(Path)),
    ok.

read_range() ->
    [{doc, "Test the read_range functionality"}].
read_range(Config) ->
    Dir = ?config(bucket_dir, Config),
    Path = filename:join([Dir, "read_range"]),
    WidthBytes = 100,
    WidthBits = 8*WidthBytes,
    Bin = <<0:WidthBits, 1:WidthBits, 2:WidthBits, 3:WidthBits, 4:WidthBits,
            5:WidthBits, 6:WidthBits, 7:WidthBits, 8:WidthBits, 9:WidthBits>>,
    revault_s3:write_file(Path, Bin),
    ?assertMatch({ok, Bin}, revault_s3:read_range(Path, 0, WidthBytes*10)),
    ?assertMatch({error, _}, revault_s3:read_range(Path, 0, WidthBytes*10+1000)),
    ?assertMatch({error, _}, revault_s3:read_range(Path, WidthBytes*1000, 1)),
    ?assertMatch({ok, <<5:100/unit:8, _:400/binary>>},
                 revault_s3:read_range(Path, WidthBytes*5, WidthBytes*5)),
    ?assertMatch({ok, <<5:100/unit:8>>},
                 revault_s3:read_range(Path, WidthBytes*5, WidthBytes)),
    ?assertMatch({ok, <<5:100/unit:8, 0>>},
                 revault_s3:read_range(Path, WidthBytes*5, WidthBytes+1)),
    ?assertEqual(ok, revault_s3:delete(Path)),
    ok.

%%%%%%%%%%%%%%%%%%%
%%% CACHE GROUP %%%
%%%%%%%%%%%%%%%%%%%
find_hashes_cached() ->
    [{doc, "exercise the hash-fetching functionality with a cache"}].
find_hashes_cached(Config) ->
    Dir = ?config(bucket_dir, Config),
    CacheDir = ?config(bucket_cache_dir, Config),
    PathA = filename:join([Dir, "subdir", "hash.txt"]),
    PathB = filename:join([Dir, "hash.txt"]),
    PathC = filename:join([Dir, "hash.ext"]),
    HashA = revault_file:hash_bin(<<"a">>),
    HashB = revault_file:hash_bin(<<"b">>),
    HashC = revault_file:hash_bin(<<"c">>),
    ?assertEqual(ok, revault_s3:write_file(PathA, <<"a">>)),
    ?assertEqual(ok, revault_s3:write_file(PathB, <<"b">>)),
    ?assertEqual(ok, revault_s3:write_file(PathC, <<"c">>)),
    ?assertEqual(ok, revault_s3_cache:ensure_loaded(Dir)),
    ?assertEqual([{<<"subdir/hash.txt">>, HashA},
                  {<<"hash.txt">>, HashB},
                  {<<"hash.ext">>, HashC}],
                 lists:reverse(lists:sort(
                    revault_s3:find_hashes(Dir, fun(_) -> true end)
                 ))),
    ?assertMatch({ok, {HashA, _}}, revault_s3_cache:hash(Dir, <<"subdir/hash.txt">>)),
    ?assertMatch({ok, {HashB, _}}, revault_s3_cache:hash(Dir, <<"hash.txt">>)),
    ?assertMatch({ok, {HashC, _}}, revault_s3_cache:hash(Dir, <<"hash.ext">>)),
    {ok, {_, LastModified}} = revault_s3_cache:hash(Dir, <<"hash.txt">>),
    revault_s3_cache:hash_store(Dir, <<"hash.txt">>, {<<"deadbeef">>, LastModified}),
    %% if we don't save, the next invocation gets crushed
    revault_s3_cache:save(Dir),
    ?assertEqual([{<<"subdir/hash.txt">>, HashA},
                  {<<"hash.txt">>, <<"deadbeef">>},
                  {<<"hash.ext">>, HashC}],
                 lists:reverse(lists:sort(
                    revault_s3:find_hashes(Dir, fun(_) -> true end)
                 ))),
    ?assertEqual(ok, revault_s3:delete(PathA)),
    ?assertEqual(ok, revault_s3:delete(PathB)),
    ?assertEqual(ok, revault_s3:delete(PathC)),
    ?assertEqual(ok, revault_s3:delete(filename:join([CacheDir, Dir]))),
    ok.

%%%%%%%%%%%%%%%
%%% PRIVATE %%%
%%%%%%%%%%%%%%%

setup_aws(Config0) ->
    {ok, Apps} = application:ensure_all_started(aws),
    Config = setup_aws_config(Config0),
    Cmd = unicode:characters_to_list(
        ["aws sts assume-role --role-arn ", ?config(role_arn, Config),
         " --role-session-name ", ?config(role_session_name, Config),
         " --output json --no-cli-pager"]
    ),
    JSON = unicode:characters_to_binary(os:cmd(Cmd)),
    ct:pal("~ts -> ~ts", [Cmd, JSON]),
    Map = jsx:decode(JSON),
    #{<<"Credentials">> := #{
        <<"AccessKeyId">> := AccessKeyId,
        <<"Expiration">> := Expiration,
        <<"SecretAccessKey">> := SecretAccessKey,
        <<"SessionToken">> := SessionToken
    }} = Map,
    ct:pal("Creds valid until ~ts", [Expiration]),
    Client = aws_client:make_temporary_client(AccessKeyId, SecretAccessKey, SessionToken, ?config(region, Config)),
    [{aws_key_id, AccessKeyId},
     {aws_secret_access_key, SecretAccessKey},
     {aws_session_token, SessionToken},
     {aws_client, Client},
     {apps, Apps}
     | Config].

setup_aws_config(Config) ->
    %% TODO: don't hardcode this, use a config mechanism
    [{role_arn, <<"arn:aws:iam::874886211697:role/ReVault-s3">>},
     {role_session_name, <<"test-suite">>},
     {region, <<"us-east-2">>},
     {bucket, <<"revault-airm1">>},
     {bucket_dir, <<"test">>},
     {bucket_cache_dir, <<"test-cache">>}
     | Config].

assert_dir_empty(_, []) -> ok;
assert_dir_empty(Prefix, [#{<<"Key">> := Key}|T]) ->
    ?assertNotMatch([Prefix|_], filename:split(Key)),
    assert_dir_empty(Prefix, T).

hash(Bin) ->
    base64:encode(crypto:hash(sha256, Bin)).
