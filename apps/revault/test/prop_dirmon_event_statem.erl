-module(prop_dirmon_event_statem).
-include_lib("proper/include/proper.hrl").
-define(DIR, "_build/test/scratch").
-define(LISTENER_NAME, {?MODULE, ?DIR}).
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
   "logically does when the disk is abstracted, and is forwarded as events".
prop_test() ->
    ?SETUP(fun() ->
        {ok, Apps} = application:ensure_all_started(gproc),
        fun() ->
             [application:stop(App) || App <- Apps],
             revault_test_utils:teardown_scratch_dir(?DIR) % safety
        end
    end,
    ?FORALL(Cmds, commands(?MODULE),
            begin
                revault_test_utils:teardown_scratch_dir(?DIR),
                revault_test_utils:setup_scratch_dir(?DIR),
                {ok, _} = revault_dirmon_event:start_link(
                    ?LISTENER_NAME,
                    #{directory => ?DIR,
                      poll_interval => 6000000} % too long to interfere
                ),
                Listener = spawn_link(fun listener/0),
                {History, State, Result} = run_commands(?MODULE, Cmds),
                Listener ! stop,
                revault_dirmon_event:stop(?LISTENER_NAME),
                revault_test_utils:teardown_scratch_dir(?DIR),
                ?WHENFAIL(io:format("History: ~p\nState: ~p\nResult: ~p\n",
                                    [History,State,Result]),
                          aggregate(command_names(Cmds), Result =:= ok))
            end)).

%%%%%%%%%%%%%
%%% MODEL %%%
%%%%%%%%%%%%%
%% @doc Initial model value at system start. Should be deterministic.
initial_state() ->
    #{ops => [],
      snapshot => dirmodel:new(),
      model => dirmodel:new()}.

%% @doc List of possible commands to run against the system
command(#{model := T}) ->
    Calls = [
        ?LAZY(dirmodel:file_add(?DIR, T)),
        {call, ?MODULE, wait_events, []}
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
postcondition(State, {call, _, wait_events, []}, Ret) ->
    {ExpDel, ExpAdd, ExpMod} = merge_ops(
        [{Op, {F,C}} || {Op, {F,C}} <- maps:get(ops, State)],
        maps:get(snapshot, State)
    ),
    Res = hash({ExpDel, ExpAdd, ExpMod}) =:= Ret,
    Res orelse io:format("===~n~p~n---~n~p~n===~n",
                         [{ExpDel, ExpAdd, ExpMod}, Ret]),
    Res;
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
next_state(State, _Res, {call, _, wait_events, []}) ->
    State#{ops := [],
           snapshot := maps:get(model, State)};
next_state(State, _Res, _Op = {call, _Mod, _Fun, _Args}) ->
    NewState = State,
    NewState.

%%%%%%%%%%%%%%%%%%%
%%% MODEL CALLS %%%
%%%%%%%%%%%%%%%%%%%
wait_events() ->
    ok = revault_dirmon_event:force_scan(?LISTENER_NAME, 5000), % sync call
    Ref = make_ref(),
    ?MODULE ! {read, self(), Ref},
    receive
        {Ref, Resp} -> Resp
    end.

%%%%%%%%%%%%%%%
%%% HELPERS %%%
%%%%%%%%%%%%%%%

%% take all operations that have run since a snapshot, and
%% reduce them down to the view since then. For example, a
%% file that is deleted, then created, might just be a "change"
%% when detected.
merge_ops(Ops, Snapshot) ->
    Map = maps:from_list([{File, {Op, Content}}
                          || {Op, {File, Content}} <- lists:reverse(Ops)]),
    process_ops(Map, Snapshot).

process_ops(Map, Snapshot) ->
    {Del, Add, Mod} = maps:fold(
        fun(File, Ops, {Del, Add, Mod}) ->
            Init = dirmodel:type(?DIR, Snapshot, File),
            case {Ops, Init} of
                %% unchanged over both polls
                {{delete, _Content}, undefined} ->
                    {Del, Add, Mod};
                %% deleted file
                {{delete, _Content}, {file, _, OldContent}} ->
                    {[{File, OldContent}|Del], Add, Mod};
                %% sequence ended in added file
                {{_, Content}, undefined} ->
                    {Del, [{File, Content}|Add], Mod};
                %% changes had no impact
                {{_, Content}, {file, _, Content}} ->
                    {Del, Add, Mod};
                %% sequence ended in changed file
                {{_, Content}, _} ->
                    {Del, Add, [{File, Content}|Mod]}
            end
        end,
        {[], [], []},
        Map
    ),
    {lists:sort(Del), lists:sort(Add), lists:sort(Mod)}.

hash({Del, Add, Mod}) ->
    F = fun({F, Content}) -> {F, crypto:hash(sha256, Content)} end,
    {lists:map(F, Del), lists:map(F, Add), lists:map(F, Mod)}.

listener() ->
    register(?MODULE, self()),
    true = gproc:reg({p, l, ?LISTENER_NAME}),
    listener([], [], []).

listener(Del, Add, Mod) ->
    receive
        {dirmon, ?LISTENER_NAME, Event} ->
            case Event of
                {deleted, Entry} -> listener([Entry|Del], Add, Mod);
                {added, Entry} -> listener(Del, [Entry|Add], Mod);
                {changed, Entry} -> listener(Del, Add, [Entry|Mod])
            end;
        {read, Pid, Ref} ->
            Pid ! {Ref, {lists:sort(Del), lists:sort(Add), lists:sort(Mod)}},
            listener([], [], []);
        stop ->
            unregister(?MODULE),
            ok
    end.
