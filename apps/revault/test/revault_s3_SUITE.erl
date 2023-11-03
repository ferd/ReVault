-module(revault_s3_SUITE).
-compile(export_all).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [client_cache].

init_per_testcase(client_cache, Config) ->
    %% 15 minutes + 2 secs, knowing we refresh at 15 mins from timeout
    FutureOffset = (timer:minutes(15) + timer:seconds(2))
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
init_per_testcase(_, Config) ->
    Config.

end_per_testcase(_, Config) ->
    gen_server:stop(?config(serv, Config)),
    meck:unload(revault_s3_serv),
    Config.

%%%%%%%%%%%%%%%%%%%
%%% CACHE CASES %%%
%%%%%%%%%%%%%%%%%%%
client_cache() ->
    [{docs, "look at the client cache and whether it works fine "
            "for automated refreshes and retry expirations"}].
client_cache(Config) ->
    ?assert(is_map(revault_s3_serv:get_client())),
    ?assert(is_map(revault_s3_serv:get_client())),
    %% only one call to STS
    ?assertMatch(
       [{_, {revault_s3_serv, cmd, ["aws sts"++_]}, _}],
       [MFA || MFA = {_, {revault_s3_serv, cmd, _}, _} <- meck:history(revault_s3_serv, ?config(serv, Config))]
    ),
    timer:sleep(timer:seconds(3)),
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
