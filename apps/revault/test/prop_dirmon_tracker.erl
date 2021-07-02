-module(prop_dirmon_tracker).
-include_lib("proper/include/proper.hrl").
-define(DIR, "_build/test/scratch").
-define(STORE, "_build/test/scratchstore").
-define(LISTENER_NAME, {?MODULE, ?DIR}).
-define(ITC_SEED, element(1, itc:explode(itc:seed()))).
-compile(export_all).

%% Model Callbacks
-export([command/1, initial_state/0, next_state/3,
         precondition/2, postcondition/3]).

%%%%%%%%%%%%%%%%%%
%%% PROPERTIES %%%
%%%%%%%%%%%%%%%%%%
prop_test(doc) ->
   "files are added, changed, and removed, and the model checks that between "
   "any two scans, the data discovered on disk matches what the operation "
   "logically does when the disk is abstracted, and is forwarded as events, "
   "which are then used to carry a stateful versioned snapshot of hashes in memory".
prop_test() ->
    ?SETUP(fun() ->
        {ok, Apps} = application:ensure_all_started(gproc),
        fun() ->
             [application:stop(App) || App <- Apps],
             file:delete(?STORE),
             revault_test_utils:teardown_scratch_dir(?DIR) % safety
        end
    end,
    ?FORALL(Cmds, commands(?MODULE),
            begin
                revault_test_utils:teardown_scratch_dir(?DIR),
                revault_test_utils:setup_scratch_dir(?DIR),
                {ok, _Listener} = revault_dirmon_tracker:start_link(
                    ?LISTENER_NAME,
                    ?DIR,
                    ?STORE,
                    ?ITC_SEED
                ),
                {ok, _} = revault_dirmon_event:start_link(
                    ?LISTENER_NAME,
                    #{directory => ?DIR,
                      initial_sync => tracker,
                      poll_interval => 6000000} % too long to interfere
                ),
                {History, State, Result} = run_commands(?MODULE, Cmds),
                revault_dirmon_event:stop(?LISTENER_NAME),
                revault_dirmon_tracker:stop(?LISTENER_NAME),
                file:delete(?STORE),
                revault_test_utils:teardown_scratch_dir(?DIR),
                ?WHENFAIL(io:format("History: ~p\nState: ~p\nResult: ~p\n",
                                    [History,State,Result]),
                          aggregate(command_names(Cmds), Result =:= ok))
            end)).

prop_monotonic(doc) ->
    "Do a sequence of random operations on a file and make sure that all "
    "operations end in a logical clock always increasing, showing data is "
    "properly tracked. Due to concurrency issue between a directory scanner "
    "and syncing, we willingly omit redundant changes from the set".
prop_monotonic() ->
    ?SETUP(fun() ->
        {ok, Apps} = application:ensure_all_started(gproc),
        fun() ->
             [application:stop(App) || App <- Apps],
             ok
        end
    end,
    ?FORALL(Events, change_events("test-file"),
      ?TRAPEXIT(
        begin
            {Id, _} = itc:explode(itc:seed()),
            {ok, Listener} = revault_dirmon_tracker:start_link(
                ?LISTENER_NAME,
                ?DIR,
                undefined,
                Id
            ),
            Hashes = lists:map(
                fun(Event) ->
                    Listener ! Event,
                    revault_dirmon_tracker:file(?LISTENER_NAME, "test-file")
                end,
                Events
            ),
            revault_dirmon_tracker:stop(?LISTENER_NAME),
            Sorter = fun({A,_}, {B,_}) ->
                itc:leq(itc:rebuild(Id, A), itc:rebuild(Id, B))
            end,
            Sorted = lists:usort(Sorter, Hashes),
            ?WHENFAIL(io:format("Ops: ~p~nSorted: ~p~nObtained: ~p~n",
                                [Events, Sorted, lists:usort(Hashes)]),
                      Sorted =:= lists:usort(Hashes) andalso
                      not lists:member(undefined, Hashes))
        end))).


%%%%%%%%%%%%%
%%% MODEL %%%
%%%%%%%%%%%%%
%% @doc Initial model value at system start. Should be deterministic.
initial_state() ->
    #{ops => [],
      snapshot => dirmodel:new(),
      model => dirmodel:new()}.

%% @doc List of possible commands to run against the system
command(#{model := T, ops := Ops}) ->
    Calls = [
        ?LAZY(dirmodel:file_add(?DIR, T)),
        {call, ?MODULE, check_files, [?DIR, T, Ops]},
        {call, ?MODULE, restart_tracker, []},
        {call, ?MODULE, restart_event, []}
    ]
    ++ case dirmodel:has_files(T) of
        false ->
            [];
        true ->
            [?LAZY(dirmodel:file_change(?DIR, T)),
             ?LAZY(dirmodel:file_delete(?DIR, T))]
    end,
    oneof(Calls).

%% @doc Determines whether a command should be valid under the
%% current state.
precondition(#{model := T}, {call, _, write_file, [Filename, _Contents | _]}) ->
    dirmodel:type(?DIR, T, Filename) =:= undefined;
precondition(#{model := T}, {call, _, change_file, [Filename, Contents | _]}) ->
    Type = dirmodel:type(?DIR, T, Filename),
    is_tuple(Type) andalso
    element(1, Type) =:= file andalso
    element(3, Type) =/= Contents;
precondition(#{model := T}, {call, _, delete_file, [Filename | _]}) ->
    case dirmodel:type(?DIR, T, Filename) of
        {file, _, _} -> true;
        _ -> false
    end;
precondition(#{model := T1}, {call, _, check_files, [_, T2, _]}) ->
    dirmodel:hashes(?DIR, T1) =:= dirmodel:hashes(?DIR, T2);
precondition(_State, {call, _Mod, _Fun, _Args}) ->
    true.

%% @doc Given the state `State' *prior* to the call
%% `{call, Mod, Fun, Args}', determine whether the result
%% `Res' (coming from the actual system) makes sense.
postcondition(_State, {call, _, write_file, _}, ok) ->
    true;
postcondition(_State, {call, _, change_file, _}, ok) ->
    true;
postcondition(_State, {call, _, delete_file, _}, ok) ->
    true;
postcondition(State, {call, _, check_files, _}, {Exist, Deleted, Unknown}) ->
    Model = maps:get(model, State),
    ModelExist = [{revault_file:make_relative(?DIR, F), H}
                  || {F,H} <- dirmodel:hashes(?DIR, Model)],
    Res = lists:sort(ModelExist) =:= lists:sort(Exist)
          andalso lists:all(fun({_Vsn, deleted}) -> true; (_) -> false end, Deleted)
          andalso lists:all(fun(Entry) -> Entry == undefined end, Unknown),
    Res orelse io:format("BAD CHECK: ~p~n~p", [{Exist, Deleted, Unknown}, ModelExist]),
    Res;
postcondition(_State, {call, _, restart_tracker, _}, {ok, _}) ->
    true;
postcondition(_State, {call, _, restart_event, _}, {ok, _}) ->
    true;
postcondition(_State, {call, _Mod, _Fun, _Args}, _Res) ->
    false.

%% @doc Assuming the postcondition for a call was true, update the model
%% accordingly for the test to proceed.
next_state(State, _Res, Op = {call, _, write_file, [FileName, Contents | _]}) ->
    State#{ops => [{add, {FileName, Contents}} | maps:get(ops, State)],
           model => dirmodel:apply_call(?DIR, maps:get(model, State), Op)};
next_state(State, _Res, Op = {call, _, change_file, [FileName, Contents | _]}) ->
    State#{ops => [{change, {FileName, Contents}} | maps:get(ops, State)],
           model => dirmodel:apply_call(?DIR, maps:get(model, State), Op)};
next_state(State, _Res, Op = {call, _, delete_file, [FileName | _]}) ->
    {file, _, Val} = dirmodel:type(?DIR, maps:get(model, State), FileName),
    State#{ops => [{delete, {FileName, Val}} | maps:get(ops, State)],
           model => dirmodel:apply_call(?DIR, maps:get(model, State), Op)};
next_state(State, _Res, {call, _, check_files, _}) ->
    State#{ops := [],
           snapshot := maps:get(model, State)};
next_state(State, _Res, _Op = {call, _Mod, _Fun, _Args}) ->
    NewState = State,
    NewState.

%%%%%%%%%%%%%%%%%%%
%%% MODEL CALLS %%%
%%%%%%%%%%%%%%%%%%%
%% @doc The role of the tracker is to provide a stable abstraction of
%% the current state on disk, by using some versioning mechanism that
%% allows comparison of valid or outdated states (eventually: conflicting ones).
%% At a later point, we'll then be able to forward state updates to other
%% nodes as events and ask these to apply the changes, which they'll be
%% able to handle properly.
%%
%% So the role should be: give me the last state and known version of the file:
%% - {Vsn, deleted}
%% - {Vsn, Hash}
%% - undefined
%%
%% This shim wrapper therefore makes a call to scan all known files (plus unknown
%% ones) to make sure they're truly gone.
check_files(Dir, Model, Ops) ->
    ok = revault_dirmon_event:force_scan(?LISTENER_NAME, 5000), % sync call
    KnownFiles = [revault_file:make_relative(Dir, File)
                  || {File, _Hash} <- dirmodel:hashes(Dir, Model)],
    KnownHashes = [{File,
                    drop_vsn(revault_dirmon_tracker:file(?LISTENER_NAME, File))}
                   || File <- KnownFiles],
    DeletedFiles = [revault_file:make_relative(Dir, File)
                    || {delete, {File, _Hash}} <- Ops,
                       file_deleted(File, Dir, Model, Ops)],
    DeletedData = [{File,
                    drop_vsn(revault_dirmon_tracker:file(?LISTENER_NAME, File))}
                   || File <- DeletedFiles],
    {KnownHashes, DeletedData,
     [revault_dirmon_tracker:file(?LISTENER_NAME,
                                  "this file has got to be bad")]}.

drop_vsn({_Vsn, Hash}) -> Hash;
drop_vsn(undefined) -> undefined.

%% @private check that the file is deleted, but also that it was deleted
%% only *after* a prior check. Otherwise, we're checking between two scans
%% and it's possible that the file was added and then deleted without
%% ever being noticed by the system. In such a case, no events will have
%% been sent to the tracker, and it is impossible for it to know about it.
file_deleted(File, Dir, Model, Ops) ->
    Type = dirmodel:type(Dir, Model, File),
    (Type =:= dir orelse Type =:= undefined)
    andalso
    [] == [Op || Op = {add, {Name, _}} <- Ops,
                         Name =:= File].

restart_tracker() ->
    revault_dirmon_tracker:stop(?LISTENER_NAME),
    revault_dirmon_tracker:start_link(?LISTENER_NAME, ?DIR, ?STORE, ?ITC_SEED).

restart_event() ->
    revault_dirmon_event:stop(?LISTENER_NAME),
    revault_dirmon_event:start_link(
        ?LISTENER_NAME,
        #{directory => ?DIR,
          initial_sync => tracker,
          poll_interval => 6000000} % too long to interfere
    ).

%%%%%%%%%%%%%%%%%%
%%% GENERATORS %%%
%%%%%%%%%%%%%%%%%%
change_events(FileName) ->
    Transform = oneof([added, deleted, changed]),
    Event = fun(Op) -> {dirmon, ?LISTENER_NAME, Op} end,
    ?LET(List, list(Event({Transform, {FileName, binary(8)}})),
         [Event({added, {FileName, binary(8)}}) | List]
    ).
