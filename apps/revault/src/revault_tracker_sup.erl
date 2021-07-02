%% @doc revault single tracker worker supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(revault_tracker_sup).

-behaviour(supervisor).

%% API
-export([start_link/5]).

%% Supervisor callbacks
-export([init/1]).
-define(registry(M, N), {via, gproc, {n, l, {M, N}}}).
-define(registry(N), ?registry(?MODULE, N)).

%%====================================================================
%% API functions
%%====================================================================

start_link(Name, Id, Path, Interval, DbDir) ->
    supervisor:start_link(?registry(Name), ?MODULE, [Name, Id, Path, Interval, DbDir]).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: #{id => Id, start => {M, F, A}}
%% Optional keys are restart, shutdown, type, modules.
%% Before OTP 18 tuples must be used to specify a child. e.g.
%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([_Name, undefined, _Path, _Interval, _DbDir]) ->
    %% If there isn't an ID we're in client mode without
    %% one even existing yet. Can't actually start, because
    %% we can't track and stamp content.
    exit(undefined_itc);
init([Name, Id, Path, Interval, DbDir]) ->
    TrackFile = filename:join(DbDir, "tracker.snapshot"),
    {ok, {{rest_for_one, 1, 60}, [
        #{id => listener,
          start => {revault_dirmon_tracker, start_link, [Name, Path, TrackFile, Id]},
          type => worker},
        #{id => event,
          start => {revault_dirmon_event, start_link,
                    [Name, #{directory => Path,
                             initial_sync => tracker,
                             poll_interval => Interval}]},
          type => worker}
    ]}}.

%%====================================================================
%% Internal functions
%%====================================================================


