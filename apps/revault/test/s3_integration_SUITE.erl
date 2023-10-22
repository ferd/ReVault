-module(s3_integration_SUITE).
-compile(export_all).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() -> [{group, api},
          {group, abstraction},
          {group, cache}].

groups() ->
    [{api, [sequence], [list_objects_empty, crud_object, rename_raw, pagination]},
     {abstraction, [sequence], [read_write_delete, hasht, copy, rename,
                                find_hashes, consult]},
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
    %% Get Hash
    ?assertMatch({ok, #{<<"ChecksumSHA256">> := NewChk}, _Http},
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
    %% Read Sode
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
