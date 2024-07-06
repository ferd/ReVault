%%%-------------------------------------------------------------------
%% @doc revault tracker worker set supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(revault_backend_sup).

-behaviour(supervisor).

%% API
-export([start_link/0,
         start_disk_subtree/1, start_s3_subtree/5,
         stop_all/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

start_disk_subtree(DirPath) ->
    %% TODO: test, particularly the multi-start paths
    supervisor:start_child(?SERVER, #{
        id => {disk_cache, DirPath},
        start => {revault_disk_cache, start_link, [DirPath]},
        type => worker
    }),
    application:set_env(revault, backend, disk),
    ok.

start_s3_subtree(RoleARN, Region, Bucket, CacheDir, DirPath) ->
    application:set_env(revault, bucket, Bucket),
    supervisor:start_child(?SERVER, #{
        id => s3_serv,
        start => {revault_s3_serv, start_link, [RoleARN, Region]},
        type => worker
    }),
    %% TODO: test, particularly the multi-start paths
    supervisor:start_child(?SERVER, #{
        id => {s3_cache, DirPath},
        start => {revault_s3_cache, start_link, [CacheDir, DirPath]},
        type => worker
    }),
    application:set_env(revault, backend, s3),
    ok.

stop_all() ->
    [supervisor:terminate_child(?SERVER, Pid)
     || {_, Pid, _, _} <- supervisor:which_children(?SERVER),
        is_pid(Pid)],
    application:set_env(revault, backend, disk),
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
