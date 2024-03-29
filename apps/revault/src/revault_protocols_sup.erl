
%%%-------------------------------------------------------------------
%% @doc revault sync fsm supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(revault_protocols_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, reset/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

reset() ->
    %% it is easiest to restart the child to drop their state and all
    %% their workers, but leave them in place to work fine later since
    %% they're expected to be around.
    [supervisor:restart_child(?SERVER, Id)
     || {Id, _, _, _} <- supervisor:which_children(?SERVER)],
    ok.

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: #{id => Id, start => {M, F, A}}
%% Optional keys are restart, shutdown, type, modules.
%% Before OTP 18 tuples must be used to specify a child. e.g.
%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
    {ok, {{one_for_one, 1, 1}, [
        #{id => revault_tcp,
          start => {revault_protocols_tcp_sup, start_link, []},
          type => supervisor},
        #{id => revault_tls,
          start => {revault_protocols_tls_sup, start_link, []},
          type => supervisor}
    ]}}.

%%====================================================================
%% Internal functions
%%====================================================================


