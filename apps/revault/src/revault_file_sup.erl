%%%-------------------------------------------------------------------
%% @doc revault tracker worker set supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(revault_file_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, start_s3_subtree/5]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

start_s3_subtree(RoleARN, Region, Bucket, CacheDir, Dir) ->
    application:set_env(revault, bucket, Bucket),
    supervisor:start_child(?SERVER, #{
        id => s3_serv,
        start => {revault_s3_serv, start_link, [RoleARN, Region]},
        type => worker
    }),
    supervisor:start_child(?SERVER, #{
        id => s3_cache,
        start => {revault_s3_cache, start_link, [CacheDir, Dir]},
        type => worker
    }),
    application:set_env(revault, backend, s3),
    ok.

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: #{id => Id, start => {M, F, A}}
%% Optional keys are restart, shutdown, type, modules.
%% Before OTP 18 tuples must be used to specify a child. e.g.
%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
    {ok, {{one_for_one, 10, 60}, []}}.
