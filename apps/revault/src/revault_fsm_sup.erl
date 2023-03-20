%%%-------------------------------------------------------------------
%% @doc revault sync fsm supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(revault_fsm_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, start_fsm/4, start_fsm/5, stop_all/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

start_fsm(DbDir, Name, Path, Interval) ->
    supervisor:start_child(?SERVER, [DbDir, Name, Path, Interval]).

start_fsm(DbDir, Name, Path, Interval, Callback) ->
    supervisor:start_child(?SERVER, [DbDir, Name, Path, Interval, Callback]).

stop_all() ->
    [supervisor:terminate_child(?SERVER, Pid)
     || {_, Pid, _, _} <- supervisor:which_children(?SERVER),
        is_pid(Pid)],
    ok.

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: #{id => Id, start => {M, F, A}}
%% Optional keys are restart, shutdown, type, modules.
%% Before OTP 18 tuples must be used to specify a child. e.g.
%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
    {ok, {{simple_one_for_one, 1, 1}, [
        #{id => revault_fsm,
          start => {revault_fsm, start_link, []},
          type => worker}
    ]}}.

%%====================================================================
%% Internal functions
%%====================================================================

