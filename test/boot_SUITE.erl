%%% @doc Check that the app boots and stops fine
-module(boot_SUITE).
-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all, nowarn_export_all]).

all() ->
    [start_stop].

start_stop(_Config) ->
    {ok, Apps} = application:ensure_all_started(maestro),
    [ok = application:stop(A) || A <- Apps],
    ok.
