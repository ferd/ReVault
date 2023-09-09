-module(s3_integration_SUITE).
-compile(export_all).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() -> [{group, api}].

groups() ->
    [{api, [sequence], [list_objects_empty, crud_object, rename, pagination]}].

init_per_suite(Config) ->
    case os:getenv("REVAULT_S3_INTEGRATION_SUITE") of
        "true" -> setup_aws(Config);
        _ -> {skip, "REVAULT_S3_INTEGRATION_SUITE != \"true\""}
    end.

end_per_suite(Config) ->
    Apps = proplists:get_value(apps, Config, []),
    [application:stop(App) || App <- lists:reverse(Apps)],
    ok.

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

rename() ->
    [{doc, "Simulate a rename operation."}].
rename(Config) ->
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
     {bucket_dir, <<"test">>}
     | Config].

assert_dir_empty(_, []) -> ok;
assert_dir_empty(Prefix, [#{<<"Key">> := Key}|T]) ->
    ?assertNotMatch([Prefix|_], filename:split(Key)),
    assert_dir_empty(Prefix, T).

hash(Bin) ->
    base64:encode(crypto:hash(sha256, Bin)).
