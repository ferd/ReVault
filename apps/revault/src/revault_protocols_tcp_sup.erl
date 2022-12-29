%%%-------------------------------------------------------------------
%% @doc revault sync fsm supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(revault_protocols_tcp_sup).

-behaviour(supervisor).

%% API
-export([start_link/0,
         start_server/1, start_server/2,
         start_client/2, start_client/3]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

start_client(Name, DirOpts) ->
    start_child(revault_tcp_client, Name, [Name, DirOpts]).

start_client(Name, DirOpts, TcpOpts) ->
    start_child(revault_tcp_client, Name, [Name, DirOpts, TcpOpts]).

start_server(DirOpts) ->
    start_child(revault_tcp_serv, shared, [DirOpts]).

start_server(DirOpts, TcpOpts) ->
    start_child(revault_tcp_serv, shared, [DirOpts, TcpOpts]).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: #{id => Id, start => {M, F, A}}
%% Optional keys are restart, shutdown, type, modules.
%% Before OTP 18 tuples must be used to specify a child. e.g.
%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
    {ok, {{one_for_one, 1, 1}, []}}.

%%====================================================================
%% Internal functions
%%====================================================================
start_child(Mod, Name, Args) ->
    supervisor:start_child(?SERVER, #{
        id => {Mod, Name},
        start => {Mod, start_link, Args},
        type => worker
    }).


