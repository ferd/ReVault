%% Cover similar content as s3_integration_SUITE, but do it with mocking
%% so we test our interface often, without paying AWS nor having to set
%% things up in a bucket.
-module(revault_s3_SUITE).
-compile(export_all).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [client_cache, consult, hash_cache, hash,
     copy, list_uncached, list_cached, is_regular,
     write_file, delete, size, multipart, multipart_hash,
     read_range].

init_per_suite(Config) ->
    InitBucket = application:get_env(revault, bucket, undefined),
    application:set_env(revault, bucket, <<"test">>),
    [{init_bucket, InitBucket} | Config].

end_per_suite(Config) ->
    case ?config(init_bucket, Config) of
        undefined -> application:unset_env(revault, bucket);
        Val -> application:set_env(revault, bucket, Val)
    end,
    Config.

init_per_testcase(client_cache, Config) ->
    %% 15 minutes + 2 secs, knowing we refresh at 15 mins from timeout
    FutureOffset = (timer:minutes(15) + timer:seconds(3))
                    div timer:seconds(1),
    FutureStamp = calendar:system_time_to_rfc3339(
            erlang:system_time(seconds)+FutureOffset
    ),
    meck:new(revault_s3_serv, [passthrough]),
    meck:expect(revault_s3_serv, cmd,
             fun("aws sts " ++ _) -> sts_string(FutureStamp)
             ;  (Str) -> meck:passthrough([Str])
             end),
    {ok, Pid} = revault_s3_serv:start_link(<<"FAKE_ARN">>, <<"FAKE_REGION">>),
    [{serv, Pid} | Config];
init_per_testcase(consult, Config) ->
    meck:new(revault_s3_serv, [passthrough]),
    meck:expect(revault_s3_serv, get_client, fun() -> #{} end),
    meck:new(aws_s3),
    Config;
init_per_testcase(hash_cache, Config) ->
    {ok, Apps} = application:ensure_all_started(gproc),
    {ok, Pid} = revault_s3_cache:start_link(<<"fakedb">>, hash_cache),
    meck:new(revault_s3, [passthrough]),
    meck:expect(revault_s3, consult, fun(_) -> {error, enoent} end),
    meck:expect(revault_s3, write_file, fun(_, _) -> ok end),
    [{serv, Pid}, {apps, Apps} | Config];
init_per_testcase(list_cached, Config) ->
    {ok, Apps} = application:ensure_all_started(gproc),
    meck:new(revault_s3_serv, [passthrough]),
    meck:expect(revault_s3_serv, get_client, fun() -> #{} end),
    {ok, Pid} = revault_s3_cache:start_link(<<"fakedb">>, <<"dir">>),
    meck:new(revault_s3, [passthrough]),
    meck:expect(revault_s3, consult, fun(_) -> {error, enoent} end),
    meck:expect(revault_s3, write_file, fun(_, _) -> ok end),
    [{serv, Pid}, {apps, Apps} | Config];
init_per_testcase(_, Config) ->
    meck:new(revault_s3_serv, [passthrough]),
    meck:expect(revault_s3_serv, get_client, fun() -> #{} end),
    meck:new(aws_s3),
    Config.

end_per_testcase(_, Config) ->
    case ?config(serv, Config) of
        undefined -> ok;
        Pid -> gen_server:stop(Pid)
    end,
    catch meck:unload(revault_s3),
    catch meck:unload(revault_s3_serv),
    catch meck:unload(aws_s3),
    case ?config(apps, Config) of
        undefined -> ok;
        Apps -> [application:stop(App) || App <- lists:reverse(Apps)]
    end,
    Config.

%%%%%%%%%%%%%%%%%%%
%%% CACHE CASES %%%
%%%%%%%%%%%%%%%%%%%
client_cache() ->
    [{doc, "look at the client cache and whether it works fine "
           "for automated refreshes and retry expirations"}].
client_cache(Config) ->
    ?assertMatch(#{}, revault_s3_serv:get_client()),
    ?assertMatch(#{}, revault_s3_serv:get_client()),
    %% only one call to STS
    ?assertMatch(
       [{_, {revault_s3_serv, cmd, ["aws sts"++_]}, _}],
       [MFA || MFA = {_, {revault_s3_serv, cmd, _}, _} <- meck:history(revault_s3_serv, ?config(serv, Config))]
    ),
    timer:sleep(timer:seconds(4)),
    ?assertEqual({error, max_retry}, revault_s3_serv:get_client()),
    %% a total of 3 extra calls to STS after a failure
    ?assertMatch(
       [{_, {revault_s3_serv, cmd, ["aws sts"++_]}, _},
        {_, {revault_s3_serv, cmd, ["aws sts"++_]}, _},
        {_, {revault_s3_serv, cmd, ["aws sts"++_]}, _},
        {_, {revault_s3_serv, cmd, ["aws sts"++_]}, _}],
       [MFA || MFA = {_, {revault_s3_serv, cmd, _}, _} <- meck:history(revault_s3_serv, ?config(serv, Config))]
    ),
    %% No more extra STS calls as the condition is sticky
    ?assertEqual({error, max_retry}, revault_s3_serv:get_client()),
    ?assertMatch(
       [{_, {revault_s3_serv, cmd, ["aws sts"++_]}, _},
        {_, {revault_s3_serv, cmd, ["aws sts"++_]}, _},
        {_, {revault_s3_serv, cmd, ["aws sts"++_]}, _},
        {_, {revault_s3_serv, cmd, ["aws sts"++_]}, _}],
       [MFA || MFA = {_, {revault_s3_serv, cmd, _}, _} <- meck:history(revault_s3_serv, ?config(serv, Config))]
    ),
    %% wait a few extra seconds for a retry on a timer
    timer:sleep(timer:seconds(6)),
    ?assertEqual({error, max_retry}, revault_s3_serv:get_client()),
    ?assertMatch(
       [{_, {revault_s3_serv, cmd, ["aws sts"++_]}, _},
        {_, {revault_s3_serv, cmd, ["aws sts"++_]}, _},
        {_, {revault_s3_serv, cmd, ["aws sts"++_]}, _},
        {_, {revault_s3_serv, cmd, ["aws sts"++_]}, _},
        {_, {revault_s3_serv, cmd, ["aws sts"++_]}, _} | _],
       [MFA || MFA = {_, {revault_s3_serv, cmd, _}, _} <- meck:history(revault_s3_serv, ?config(serv, Config))]
    ),
    ok.

consult() ->
    [{doc, "look at errors for consulting a s3 file"}].
consult(_Config) ->
    %% Try an object not being found first
    meck:expect(aws_s3, get_object, fun(_, _, _) -> {error, {404, []}} end),
    ?assertEqual({error, enoent}, revault_s3:consult("fake/file")),
    %% Then try regular ones
    ?assertEqual({ok, [ok]}, revault_s3:consult(expect_consult(<<"ok.">>))),
    ?assertEqual({ok, [1,2]}, revault_s3:consult(expect_consult(<<"1. 2.\n">>))),
    ?assertEqual({ok, [1,2,[#{}]]},
                 revault_s3:consult(expect_consult(<<"1. 2.\n[#{}]. ">>))),
    ?assertEqual({error,{3,erl_parse,["syntax error before: ",[]]}},
                 revault_s3:consult(expect_consult(<<"1.\n2.\n3.3. 4">>))),
    %% Currently can't keep the line number when the error goes past the
    %% tokenisation/scan phase into the parsing.
    ?assertMatch({error,{_,erl_parse,"bad_term"}},
                 revault_s3:consult(expect_consult(<<"1.\n2.\n3.3. 4 ! ok.">>))),
    ok.

hash_cache() ->
    [{doc, "try hash cache operations, with a mocked backend"}].
hash_cache(_Config) ->
    ?assertEqual(ok, revault_s3_cache:ensure_loaded(hash_cache)),
    ?assertEqual(undefined, revault_s3_cache:hash(hash_cache, <<"key">>)),
    ?assertEqual(ok, revault_s3_cache:hash_store(hash_cache, <<"key">>,
                                                 {<<"val">>, <<"stamp">>})),
    ?assertEqual({ok, {<<"val">>, <<"stamp">>}},
                 revault_s3_cache:hash(hash_cache, <<"key">>)),
    ?assertEqual(ok, revault_s3_cache:save(hash_cache)),
    ?assertEqual({ok, {<<"val">>, <<"stamp">>}},
                 revault_s3_cache:hash(hash_cache, <<"key">>)),
    meck:expect(revault_s3, consult,
                fun(_) -> {ok, [{hash_cache, #{<<"key">> => <<"?">>}}]} end),
    ?assertEqual(ok, revault_s3_cache:ensure_loaded(hash_cache)),
    ?assertEqual({ok, <<"?">>},
                 revault_s3_cache:hash(hash_cache, <<"key">>)),
    ok.

hash() ->
    [{doc, "mocked out call to the hash function, based "
           "on data from the integration suite"}].
hash(_Config) ->
    Hash = crypto:hash(sha256, <<"fake">>),
    B64Hash = base64:encode(Hash),
    meck:expect(aws_s3, head_object,
                fun(_Cli, _Bucket, <<"a">>, #{<<"ChecksumMode">> := <<"ENABLED">>}) ->
                    {ok, #{<<"ChecksumSHA256">> => B64Hash},
                     {200, [], make_ref()}};
                   (_Cli, _Bucket, <<"a">>, _) ->
                    {ok, #{}, {200, [], make_ref()}}
                end),
    ?assertEqual(Hash, revault_s3:hash(<<"a">>)),
    ok.

copy() ->
    [{doc, "mocked out call to the copy function, based "
           "on data from the integration suite"}].
copy(_Config) ->
    meck:expect(aws_s3, copy_object,
                fun(_Cli, _Bucket, _To, #{<<"CopySource">> := _Path}, _Opts) ->
                    {ok, #{}, {200, [], make_ref()}}
                end),
    % TODO: mock and test a move from a non-existing file, maybe
    ?assertEqual(ok, revault_s3:copy(<<"from">>, <<"to">>)),
    ok.

list_uncached() ->
    [{doc, "mocked out call to the list function, based "
           "on data from the integration suite"}].
list_uncached(_Config) ->
    %% All files return the same dummy hash here
    Hash = crypto:hash(sha256, <<"fake">>),
    B64Hash = base64:encode(Hash),
    meck:expect(aws_s3, head_object,
                fun(_Cli, _Bucket, _File, #{<<"ChecksumMode">> := <<"ENABLED">>}) ->
                    {ok, #{<<"ChecksumSHA256">> => B64Hash},
                     {200, [], make_ref()}}
                end),
    %% Create a listing
    expect_list_objects_v2(),
    ?assertEqual(
       lists:sort([{<<"a">>, Hash},
                   {<<"b">>, Hash},
                   {<<"c">>, Hash},
                   {<<"d">>, Hash}]),
       lists:sort(revault_s3:find_hashes_uncached(<<"dir">>, fun(_) -> true end))
    ),
    ?assertEqual(
       lists:sort([{<<"a">>, Hash},
                   {<<"b">>, Hash},
                   {<<"d">>, Hash}]),
       lists:sort(revault_s3:find_hashes_uncached(<<"dir">>,
                                                  %% paths in filter are complete
                                                  fun(F) -> F =/= <<"dir/c">> end))
    ),
    ok.

list_cached() ->
    [{doc, "mocked out call to the list function, based "
           "on data from the integration suite"}].
list_cached(_Config) ->
    %% All files return the same dummy hash here
    Hash = crypto:hash(sha256, <<"fake">>),
    B64Hash = base64:encode(Hash),
    %% Only some files are mocked; any other file will crash, so let's rely on the cache
    meck:expect(aws_s3, head_object,
                fun(_Cli, _Bucket, File, #{<<"ChecksumMode">> := <<"ENABLED">>})
                      when File == <<"dir/a">>; File == <<"dir/b">> ->
                        {ok, #{<<"ChecksumSHA256">> => B64Hash},
                          {200, [], make_ref()}}
                end),
    %% mock out the cache file
    meck:expect(revault_s3, consult,
                fun(_) -> {ok, [{<<"dir">>,
                                   %% invalid entry (and a's missing)
                                 #{<<"b">> => {<<"bad">>, <<"old">>},
                                   %% valid entries
                                   <<"c">> => {Hash, <<"123">>},
                                   <<"d">> => {Hash, <<"123">>}}}]}
                end),
    %% Create a listing
    expect_list_objects_v2(),
    ?assertEqual(
       lists:sort([{<<"a">>, Hash},
                   {<<"b">>, Hash},
                   {<<"c">>, Hash},
                   {<<"d">>, Hash}]),
       lists:sort(revault_s3:find_hashes(<<"dir">>, fun(_) -> true end))
    ),
    %% we should be able to drop all head calls here assuming the cache
    %% was saved
    meck:expect(revault_s3, consult,
                fun(_) -> {ok, [{<<"dir">>,
                                 #{<<"a">> => {Hash, <<"123">>},
                                   <<"b">> => {Hash, <<"123">>},
                                   <<"c">> => {Hash, <<"123">>},
                                   <<"d">> => {Hash, <<"123">>}}}]}
                end),
    meck:expect(aws_s3, head_object,
                fun(_Cli, _Bucket, _, _) -> {error, this_is_invalid} end),
    ?assertEqual(
       lists:sort([{<<"a">>, Hash},
                   {<<"b">>, Hash},
                   {<<"d">>, Hash}]),
       lists:sort(revault_s3:find_hashes(<<"dir">>,
                                         %% paths in filter are complete
                                         fun(F) -> F =/= <<"dir/c">> end))
    ),
    ok.

is_regular() ->
    [{doc, "mocked out call to the is_regular function, based "
           "on data from the integration suite"}].
is_regular(_Config) ->
    Hash = crypto:hash(sha256, <<"fake">>),
    B64Hash = base64:encode(Hash),
    meck:expect(aws_s3, head_object,
                fun(_Cli, _Bucket, <<"dir/a/b">>, _) ->
                        {ok, #{<<"ChecksumSHA256">> => B64Hash},
                         {200, [], make_ref()}};
                   (_Cli, _Bucket, <<"dir/a/">>, _) ->
                        {ok, #{<<"ContentType">> => <<"application/x-directory; charset=UTF-8">>,
                               <<"ContentLength">> => <<"0">>},
                         {200, [], make_ref()}};
                   (_Cli, _Bucket, <<"dir/a">>, _) ->
                        {ok, #{<<"ContentType">> => <<"application/x-directory; charset=UTF-8">>,
                               <<"ContentLength">> => <<"0">>},
                         {200, [], make_ref()}};
                   (_Cli, _Bucket, <<"dir">>, _) ->
                        {ok, #{<<"ContentType">> => <<"application/x-directory; charset=UTF-8">>,
                               <<"ContentLength">> => <<"0">>},
                         {200, [], make_ref()}};
                   (_Cli, _Bucket, <<"dir/">>, _) ->
                        {ok, #{<<"ContentType">> => <<"application/x-directory; charset=UTF-8">>,
                               <<"ContentLength">> => <<"0">>},
                         {200, [], make_ref()}};
                   (_Cli, _Bucket, _Path, _) ->
                        {error, {404, []}}
                end),
    ?assert(revault_s3:is_regular(<<"dir/a/b">>)),
    ?assertNot(revault_s3:is_regular(<<"dir/a/c">>)),
    ?assertNot(revault_s3:is_regular(<<"dir/a/">>)),
    ?assertNot(revault_s3:is_regular(<<"dir/a">>)),
    ?assertNot(revault_s3:is_regular(<<"dir/">>)),
    ?assertNot(revault_s3:is_regular(<<"dir">>)),
    ok.

write_file() ->
    [{doc, "mock out the write_file calls based on the integration suite"}].
write_file(_Config) ->
    Hash = crypto:hash(sha256, <<"data">>),
    B64Hash = base64:encode(Hash),
    meck:expect(aws_s3, put_object,
                fun(_Cli, _Bucket, <<"a">>,
                    #{<<"Body">> := <<"data">>,
                      <<"ChecksumAlgorithm">> := _,
                      <<"ChecksumSHA256">> := B64}, _) when B64 == B64Hash ->
                    {ok, #{<<"ChecksumSHA256">> => B64Hash},
                     {200, [], make_ref()}}
                end),
    ?assertEqual(ok, revault_s3:write_file(<<"a">>, <<"data">>)),
    ok.

delete() ->
    [{doc, "mock out the delete calls based on the integration suite"}].
delete(_Config) ->
    %% Always returns an inconditional 204
    meck:expect(aws_s3, delete_object,
                fun(_Cli, _Bucket, _, _) ->
                    {ok, #{}, {204, [], make_ref()}}
                end),
    ?assertEqual(ok, revault_s3:delete(<<"a">>)),
    ok.

size() ->
    [{doc, "mocked out call to the size function, based "
           "on data from the integration suite"}].
size(_Config) ->
    meck:expect(aws_s3, head_object,
                fun(_Cli, _Bucket, <<"a">>, _) ->
                    {ok, #{<<"ContentLength">> => <<"1234">>},
                     {200, [], make_ref()}}
                end),
    ?assertEqual({ok, 1234}, revault_s3:size(<<"a">>)),
    ok.

multipart() ->
    [{doc, "mocked out call to the multipart functions, based "
           "on data from the integration suite"}].
multipart(_Config) ->
    UploadId = <<"123456">>,
    P1 = <<1>>,
    P2 = <<2>>,
    P3 = <<3>>,
    Whole = <<P1/binary,P2/binary,P3/binary>>,
    H1 = revault_file:hash_bin(P1),
    H2 = revault_file:hash_bin(P2),
    H3 = revault_file:hash_bin(P3),
    HA = revault_file:hash_bin(Whole),
    CM = << (base64:encode(revault_file:hash_bin(<<H1/binary, H2/binary, H3/binary>>)))/binary, "-3" >>,
    CA = base64:encode(HA),
    meck:expect(aws_s3, create_multipart_upload,
                fun(_Cli, _Bucket, _Path, _Query, _Opts) ->
                    {ok, #{<<"InitiateMultipartUploadResult">> =>
                           #{<<"UploadId">> => UploadId}},
                     {200, [], make_ref()}}
                end),
    meck:expect(aws_s3, upload_part,
                fun(_Cli, _Bucket, _Path,
                    #{<<"PartNumber">> := _, <<"ChecksumSHA256">> := Chk},
                    _Opts) ->
                    {ok, #{<<"ETag">> => Chk, <<"ChecksumSHA256">> => Chk}, {200, [], make_ref()}}
                end),
    meck:expect(aws_s3, complete_multipart_upload,
                fun(_Cli, _Bucket, _Path, _Query, _Opts) ->
                    {ok, #{<<"CompleteMultipartUploadResult">> =>
                           #{<<"ChecksumSHA256">> => CM}},
                     {200, [], make_ref()}}
                end),
    meck:expect(aws_s3, copy_object,
                fun(_Cli, _Bucket, _To, _Query, _Opts) ->
                    {ok, #{<<"CopyObjectResult">> => #{<<"ChecksumSHA256">> => CA}}, {200, []}}
                end),
    meck:expect(aws_s3, delete_object,
                fun(_Cli, _Bucket, _Path, _Query) -> {ok, #{}, {200, []}} end),
    S0 = revault_s3:multipart_init(<<"path">>, 3, HA),
    {ok, S1} = revault_s3:multipart_update(S0, <<"path">>, 1, 3, HA, P1),
    {ok, S2} = revault_s3:multipart_update(S1, <<"path">>, 2, 3, HA, P2),
    {ok, S3} = revault_s3:multipart_update(S2, <<"path">>, 3, 3, HA, P3),
    ?assertEqual(ok, revault_s3:multipart_final(S3, <<"path">>, 3, HA)),
    ok.

multipart_hash() ->
    [{doc, "mocked out call to the multipart functions, based "
           "on data from the integration suite, checking checksums."}].
multipart_hash(_Config) ->
    UploadId = <<"123456">>,
    P1 = <<1>>,
    P2 = <<2>>,
    P3 = <<3>>,
    Whole = <<P1/binary,P2/binary,P3/binary>>,
    H1 = revault_file:hash_bin(P1),
    H2 = revault_file:hash_bin(P2),
    H3 = revault_file:hash_bin(P3),
    HA = <<1, (revault_file:hash_bin(Whole))/binary>>,
    CM = << (base64:encode(revault_file:hash_bin(<<H1/binary, H2/binary, H3/binary>>)))/binary, "-3" >>,
    CA = base64:encode(HA),
    meck:expect(aws_s3, create_multipart_upload,
                fun(_Cli, _Bucket, _Path, _Query, _Opts) ->
                    {ok, #{<<"InitiateMultipartUploadResult">> =>
                           #{<<"UploadId">> => UploadId}},
                     {200, [], make_ref()}}
                end),
    meck:expect(aws_s3, upload_part,
                fun(_Cli, _Bucket, _Path,
                    #{<<"PartNumber">> := _, <<"ChecksumSHA256">> := Chk},
                    _Opts) ->
                    {ok, #{<<"ETag">> => Chk, <<"ChecksumSHA256">> => Chk}, {200, [], make_ref()}}
                end),
    meck:expect(aws_s3, complete_multipart_upload,
                fun(_Cli, _Bucket, _Path, _Query, _Opts) ->
                    {ok, #{<<"CompleteMultipartUploadResult">> =>
                           #{<<"ChecksumSHA256">> => CM}},
                     {200, [], make_ref()}}
                end),
    meck:expect(aws_s3, copy_object,
                fun(_Cli, _Bucket, _To, _Query, _Opts) ->
                    {ok, #{<<"CopyObjectResult">> => #{<<"ChecksumSHA256">> => CA}}, {200, []}}
                end),
    meck:expect(aws_s3, delete_object,
                fun(_Cli, _Bucket, _Path, _Query) -> {ok, #{}, {200, []}} end),
    S0 = revault_s3:multipart_init(<<"path">>, 3, HA),
    {ok, S1} = revault_s3:multipart_update(S0, <<"path">>, 1, 3, HA, P1),
    {ok, S2} = revault_s3:multipart_update(S1, <<"path">>, 2, 3, HA, P2),
    {ok, S3} = revault_s3:multipart_update(S2, <<"path">>, 3, 3, HA, P3),
    ?assertError(invalid_hash, revault_s3:multipart_final(S3, <<"path">>, 3, HA)),
    ok.

read_range() ->
    [{doc, "mocked out call to the read object functions, based "
           "on data from the integration suite"}].
read_range(_Config) ->
    WidthBytes = 100,
    WidthBits = 8*WidthBytes,
    Bin = <<0:WidthBits, 1:WidthBits, 2:WidthBits, 3:WidthBits, 4:WidthBits,
            5:WidthBits, 6:WidthBits, 7:WidthBits, 8:WidthBits, 9:WidthBits>>,
    Path = "whatever",
    meck:expect(aws_s3, get_object,
                fun(_Client, _Bucket, _Path, _Query, #{<<"Range">> := <<"bytes=", Trail/binary>>}) ->
                    [StartBin,EndBin] = binary:split(Trail, <<"-">>),
                    Start = binary_to_integer(StartBin),
                    End = binary_to_integer(EndBin),
                    Width = (End-Start)+1,
                    case Bin of
                        <<_:Start/binary, Part:Width/binary, _/binary>> ->
                            {ok, #{<<"Body">> => Part,
                                   <<"ContentLength">> => integer_to_binary(byte_size(Part))},
                             {200, []}};
                        <<_:Start/binary, Rest/binary>> ->
                            {ok, #{<<"Body">> => Rest,
                                   <<"ContentLength">> => integer_to_binary(byte_size(Rest))},
                             {200, []}};
                        _ ->
                            {error, #{<<"Error">> => #{<<"Code">> => <<"InvalidRange">>}}, {400,[]}}
                    end
                end),
    ?assertMatch({ok, Bin}, revault_s3:read_range(Path, 0, WidthBytes*10)),
    ?assertMatch({error, _}, revault_s3:read_range(Path, 0, WidthBytes*10+1000)),
    ?assertMatch({error, _}, revault_s3:read_range(Path, WidthBytes*1000, 1)),
    ?assertMatch({ok, <<5:100/unit:8, _:400/binary>>},
                 revault_s3:read_range(Path, WidthBytes*5, WidthBytes*5)),
    ?assertMatch({ok, <<5:100/unit:8>>},
                 revault_s3:read_range(Path, WidthBytes*5, WidthBytes)),
    ?assertMatch({ok, <<5:100/unit:8, 0>>},
                 revault_s3:read_range(Path, WidthBytes*5, WidthBytes+1)),
    ok.


%% rename is just a copy+delete, ignore it.

%%%%%%%%%%%%%%%
%%% PRIVATE %%%
%%%%%%%%%%%%%%%
sts_string(Stamp) ->
"{
    \"Credentials\": {
        \"AccessKeyId\": \"FAKEKEYID\",
        \"SecretAccessKey\": \"FAKESECRETACCESSKEY\",
        \"SessionToken\": \"FAKE_SESSION_TOKEN\",
        \"Expiration\": \""++Stamp++"\"
    },
    \"AssumedRoleUser\": {
        \"AssumedRoleId\": \"FAKEROLEID:testing-cli\",
        \"Arn\": \"arn:aws:sts::0123456789:assumed-role/ReVault-s3/testing-cli\"
    }
}".

expect_consult(Bin) ->
    meck:expect(aws_s3, get_object,
                fun(_, _, _) ->
                    {ok, #{<<"Body">> => Bin},
                     {200, [], make_ref()}}
                end),
    Bin.

expect_list_objects_v2() ->
    meck:expect(aws_s3, list_objects_v2,
                fun(_Cli, _Bucket, M=#{<<"prefix">> := _}, _) when not is_map_key(<<"continuation-token">>, M) ->
                    {ok,
                     #{<<"ListBucketResult">> =>
                       #{<<"KeyCount">> => <<"1">>,
                         <<"Contents">> => [
                            #{<<"Key">> => <<"dir/a">>, <<"LastModified">> => <<"123">>}
                        ]},
                       <<"IsTruncated">> => <<"true">>,
                       <<"NextContinuationToken">> => <<"a">>},
                     {200, [], make_ref()}};
                   (_Cli, _Bucket, #{<<"prefix">> := _,
                                     <<"continuation-token">> := <<"a">>}, _) ->
                    {ok,
                     #{<<"ListBucketResult">> =>
                       #{<<"KeyCount">> => <<"1">>,
                         <<"Contents">> => #{<<"Key">> => <<"dir/b">>,
                                             <<"LastModified">> => <<"123">>}},
                       <<"IsTruncated">> => <<"true">>,
                       <<"NextContinuationToken">> => <<"b">>},
                     {200, [], make_ref()}};
                   (_Cli, _Bucket, #{<<"prefix">> := _,
                                     <<"continuation-token">> := <<"b">>}, _) ->
                    {ok,
                     #{<<"ListBucketResult">> =>
                       #{<<"KeyCount">> => <<"2">>,
                         <<"Contents">> => [
                            #{<<"Key">> => <<"dir/c">>, <<"LastModified">> => <<"123">>},
                            #{<<"Key">> => <<"dir/d">>, <<"LastModified">> => <<"123">>}
                        ]},
                       <<"IsTruncated">> => <<"true">>,
                       <<"NextContinuationToken">> => <<"d">>},
                     {200, [], make_ref()}};
                   (_Cli, _Bucket, #{<<"prefix">> := _,
                                     <<"continuation-token">> := <<"d">>}, _) ->
                    {ok,
                     #{<<"ListBucketResult">> => #{<<"KeyCount">> => <<"0">>}},
                     {200, [], make_ref()}}
                end).
