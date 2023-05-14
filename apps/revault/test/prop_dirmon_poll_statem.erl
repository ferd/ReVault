-module(prop_dirmon_poll_statem).
-include_lib("proper/include/proper.hrl").
-define(DIR, "_build/test/scratch").
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
   "logically does when the disk is abstracted.".
prop_test() ->
    ?FORALL(Cmds, commands(?MODULE),
            begin
                revault_test_utils:teardown_scratch_dir(?DIR),
                revault_test_utils:setup_scratch_dir(?DIR),
                {History, State, Result} = run_commands(?MODULE, Cmds),
                revault_test_utils:teardown_scratch_dir(?DIR),
                ?WHENFAIL(io:format("History: ~p\nState: ~p\nResult: ~p\n",
                                    [History,State,Result]),
                          aggregate(command_names(Cmds), Result =:= ok))
            end).

%%%%%%%%%%%%%
%%% MODEL %%%
%%%%%%%%%%%%%
%% @doc Initial model value at system start. Should be deterministic.
initial_state() ->
    #{ops => [],
      set => [],
      snapshot => dirmodel:new(),
      model => dirmodel:new()}.

%% @doc List of possible commands to run against the system
command(#{model := T, set := Set}) ->
    Calls = [
        ?LAZY(dirmodel:file_add(?DIR, T)),
        {call, revault_dirmon_poll, rescan, [?DIR, [], Set]}
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
postcondition(State, {call, _, rescan, [_, _, _]}, Ret) ->
    {ExpDel, ExpAdd, ExpMod} = merge_ops(
        [{Op, {F,C}} || {Op, {F,C}} <- maps:get(ops, State)],
        maps:get(snapshot, State)
    ),
    ExpSet = dirmodel:hashes(maps:get(model, State)),
    Res = {hash({ExpDel, ExpAdd, ExpMod}), ExpSet} =:= Ret,
    Res orelse io:format("===~n~p~n---~n~p~n===~n",
                         [{hash({ExpDel, ExpAdd, ExpMod}), ExpSet}, Ret]),
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
next_state(State, Res, {call, _, rescan, [_, _]}) ->
    %% Symbolic call to work around the symbolic execution issues
    %% without having to wrap the rescan calls furthermore.
    State#{set := {call, erlang, element, [2, Res]},
           ops := [],
           snapshot := maps:get(model, State)};
next_state(State, _Res, {call, _Mod, _Fun, _Args}) ->
    NewState = State,
    NewState.

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
    F = fun({F, Content}) -> {revault_file:make_relative(?DIR, F), crypto:hash(sha256, Content)} end,
    {lists:map(F, Del), lists:map(F, Add), lists:map(F, Mod)}.
