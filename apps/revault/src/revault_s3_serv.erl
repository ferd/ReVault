%% TODO: the current timeout check works on computing the relative time
%% difference between the UTC expiration and the current system time.
%% This is unsafe because computers going to sleep or system clocks
%% changing can result in a stale session staying for longer than required.
%% Change the mechanism at some point to rely on UTC time checks.
-module(revault_s3_serv).
-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export([start_link/2, start_link/3, get_client/0]).

-define(ROLE_SESSION_NAME, <<"ReVault-", (atom_to_binary(node()))/binary>>).
-define(SESSION_EXTRA_SECS, (timer:minutes(15) div timer:seconds(1))).
-record(state, {role_arn,
                region,
                session,
                client,
                expiration,
                tref}).

%% @doc Initialize the S3 stateful server. Given information
%% about which role and region to use, this module will call
%% to the AWS CLI and request temporary token based on the
%% assume-role functionality using whatever the system is
%% configured to deliver at the time. The session name
%% for the role is going to be ReVault-${the Erlang's node name}.
%%
%% The client is cached for a period of time fitting its validity
%% plus a few minutes, after which it gets refreshed.
start_link(RoleARN, Region) ->
    start_link(RoleARN, Region, ?ROLE_SESSION_NAME).

start_link(RoleARN, Region, Session) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, {RoleARN, Region, Session}, []).

%% @doc return a temporary AWS client
get_client() ->
    gen_server:call(?MODULE, client, 60000).

%%%%%%%%%%%%%%%%%
%%% CALLBACKS %%%
%%%%%%%%%%%%%%%%%
init({RoleARN, Region, Session}) ->
    {ok, #state{role_arn=RoleARN, region=Region, session=Session}}.

handle_call(client, From, S=#state{client=undefined}) ->
    handle_call(client, From, start_client(S));
handle_call(client, _From, S=#state{client=Client}) ->
    {reply, Client, S};
handle_call(_Unknown, _From, State) ->
    {noreply, State}.

handle_cast(_Ignore, State) ->
    {noreply, State}.

handle_info({timeout, Tref, old_client}, S=#state{tref=Tref}) ->
    {noreply, S#state{client=undefined, tref=undefined, expiration=undefined}};
handle_info(_Ignore, State) ->
    {noreply, State}.

%%%%%%%%%%%%%%%
%%% PRIVATE %%%
%%%%%%%%%%%%%%%
start_client(S=#state{role_arn=RoleARN, region=Region, session=Session}) ->
    Cmd = unicode:characters_to_list(
        ["aws sts assume-role --role-arn ", RoleARN,
         " --role-session-name ", Session,
         " --output json --no-cli-pager"]
    ),
    JSON = unicode:characters_to_binary(os:cmd(Cmd)),
    Map = jsx:decode(JSON),
    #{<<"Credentials">> := #{
        <<"AccessKeyId">> := AccessKeyId,
        <<"Expiration">> := Expiration,
        <<"SecretAccessKey">> := SecretAccessKey,
        <<"SessionToken">> := SessionToken
    }} = Map,
    Client = aws_client:make_temporary_client(
        AccessKeyId,
        SecretAccessKey,
        SessionToken,
        Region
    ),
    SecondsLeft = calendar:rfc3339_to_system_time(binary_to_list(Expiration)) - erlang:system_time(seconds),
    DurationMs = max(0, timer:seconds(SecondsLeft-?SESSION_EXTRA_SECS)),
    TRef = erlang:start_timer(DurationMs, self(), old_client),
    S#state{client=Client, tref=TRef, expiration=Expiration}.
