-module(dirmon_event_SUITE).
-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").
-compile(export_all).

all() ->
    [scan_with_timeouts, survive_unexpected_msgs].

init_per_testcase(_, Config) ->
    {ok, Apps} = application:ensure_all_started(gproc),
    [{apps, Apps} | Config].

end_per_testcase(_, Config) ->
    [application:stop(App) || App <- ?config(apps, Config)],
    Config.

scan_with_timeouts() ->
    [{doc, "validate that the scan is done at regular intervals based "
           "on timeouts, and that events are sent for each discovered "
           "file. Don't re-check the diff logic, which is already "
           "covered in property testing suites."}].
scan_with_timeouts(Config) ->
    PrivDir = ?config(priv_dir, Config),
    File = "a-file.txt",
    AbsFile = filename:join(PrivDir, File),
    gproc:reg({p, l, {?MODULE, ?FUNCTION_NAME}}),
    {ok, _} = revault_dirmon_event:start_link(
      {?MODULE, ?FUNCTION_NAME},
      #{directory => PrivDir, poll_interval => 10,
        ignore => [], initial_sync => scan}
    ),
    ok = file:write_file(AbsFile, "text"),
    H0 = receive
        {dirmon, {?MODULE, ?FUNCTION_NAME}, {added, {File, Hash0}}} -> Hash0
    after 5000 ->
        flush_err()
    end,
    ok = file:write_file(AbsFile, "text2"),
    H1 = receive
        {dirmon, {?MODULE, ?FUNCTION_NAME}, {changed, {File, Hash1}}} -> Hash1
    after 5000 ->
        flush_err()
    end,
    ok = file:delete(AbsFile),
    receive
        {dirmon, {?MODULE, ?FUNCTION_NAME}, {deleted, {File, H1}}} -> ok
    after 5000 ->
        flush_err()
    end,
    ?assertNotEqual(H0, H1),
    ok.

survive_unexpected_msgs() ->
    [{doc, "Just make sure that unexpected calls or messages don't kill "
           "the server as it is important."}].
survive_unexpected_msgs(Config) ->
    PrivDir = ?config(priv_dir, Config),
    {ok, Pid} = revault_dirmon_event:start_link(
      {?MODULE, ?FUNCTION_NAME},
      #{directory => PrivDir, poll_interval => 1000000,
        ignore => [], initial_sync => scan}
    ),
    Pid ! make_ref(),
    gen_server:cast(Pid, make_ref()),
    try
        gen_server:call(Pid, make_ref(), 100), % don't take too long
        error(no_response_expected)
    catch
        exit:{timeout, _} ->
            ok
    end,
    ?assert(is_process_alive(Pid)),
    ok.

%%%%%%%%%%%%%%%
%%% HELPERS %%%
%%%%%%%%%%%%%%%
flush_err() ->
    receive
        X ->
            ct:pal("message: ~p", [X]),
            flush_err()
    after 0 ->
        error(no_event)
    end.
