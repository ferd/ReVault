%%%-------------------------------------------------------------------
%% @doc revault top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(revault_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: #{id => Id, start => {M, F, A}}
%% Optional keys are restart, shutdown, type, modules.
%% Before OTP 18 tuples must be used to specify a child. e.g.
%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
    {ok, {{one_for_all, 1, 60}, [
        #{id => backend_sup,
          start => {revault_backend_sup, start_link, []},
          type => supervisor},
        #{id => trackers_sup,
          start => {revault_trackers_sup, start_link, []},
          type => supervisor},
        #{id => protocols_sup,
          start => {revault_protocols_sup, start_link, []},
          type => supervisor},
        #{id => fsm_sup,
          start => {revault_fsm_sup, start_link, []},
          type => supervisor}
    ]}}.

%%====================================================================
%% Internal functions
%%====================================================================
