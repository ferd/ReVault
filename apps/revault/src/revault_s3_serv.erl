-module(revault_s3_serv).
-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export([start_link/2, start_link/3, get_client/0]).
%% testability exports
-export([cmd/1]).

-define(ROLE_SESSION_NAME, <<"ReVault-", (atom_to_binary(node()))/binary>>).
-define(SESSION_EXTRA_SECS, (timer:minutes(15) div timer:seconds(1))).
-define(MIN_REFRESH, timer:seconds(5)).
-define(CLIENT_RETRY, 3).

-record(state, {role_arn,
                region,
                session,
                client,
                expiration,
                retry=?CLIENT_RETRY,
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
handle_call(client, From, S=#state{client=Client, expiration=Expiration, tref=TRef, retry=N}) ->
    case is_expired(Expiration) of
        false ->
            {reply, Client, S};
        true when N =< 0 ->
            %% wait for the timer to unstick, if possible; this will
            %% cause errors downstream.
            {reply, {error, max_retry}, S};
        true ->
            %% If we went to sleep or the system clock got a change, the timeout
            %% event won't get here in time, so proactively change it by
            %% refreshing the client
            erlang:cancel_timer(TRef),
            handle_call(client, From, S#state{client=undefined, tref=undefined,
                                              expiration=undefined, retry=N-1})
    end;
handle_call(_Unknown, _From, State) ->
    {noreply, State}.

handle_cast(_Ignore, State) ->
    {noreply, State}.

handle_info({timeout, Tref, old_client}, S=#state{tref=Tref}) ->
    {noreply, S#state{client=undefined, tref=undefined,
                      expiration=undefined, retry=?CLIENT_RETRY}};
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
    JSON = unicode:characters_to_binary(?MODULE:cmd(Cmd)),
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
    DurationMs = max(?MIN_REFRESH, timer:seconds(seconds_left(Expiration) - ?SESSION_EXTRA_SECS)),
    TRef = erlang:start_timer(DurationMs, self(), old_client),
    S#state{client=Client, tref=TRef, expiration=Expiration}.

is_expired(Expiration) ->
    seconds_left(Expiration) =< ?SESSION_EXTRA_SECS.

seconds_left(Expiration) ->
    calendar:rfc3339_to_system_time(binary_to_list(Expiration)) - erlang:system_time(seconds).

cmd(Str) ->
    os:cmd(Str).
