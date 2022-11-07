%%%-------------------------------------------------------------------
%% @doc revault tracker worker set supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(revault_trackers_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, start_tracker/5]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

start_tracker(Name, Id, Path, Interval, DbDir) ->
    supervisor:start_child(?SERVER, [Name, Id, Path, Interval, DbDir]).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: #{id => Id, start => {M, F, A}}
%% Optional keys are restart, shutdown, type, modules.
%% Before OTP 18 tuples must be used to specify a child. e.g.
%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
    {ok, {{simple_one_for_one, 10, 60}, [
        #{id => scanner,
          start => {revault_tracker_sup, start_link, []},
          type => supervisor}
    ]}}.

%%====================================================================
%% Internal functions
%%====================================================================

