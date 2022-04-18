
%%%-------------------------------------------------------------------
%% @doc revault sync fsm supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(revault_protocols_sup).

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
    {ok, {{one_for_one, 1, 1}, [
        #{id => revault_tcp,
          start => {revault_protocols_tcp_sup, start_link, []},
          type => supervisor}
    ]}}.

%%====================================================================
%% Internal functions
%%====================================================================


