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
    #{set => [],
      ops => [],
      dirs => []}.

%% @doc List of possible commands to run against the system
command(State) ->
    Calls = [
        {call, ?MODULE, add_file, [new_filename(State), contents()]},
        {call, revault_dirmon_poll, rescan, [?DIR, maps:get(set, State)]}
    ]
    ++ case maps:size(State) of
        3 -> % the two static atom keys
            [];
        _ ->
            [{call, ?MODULE, change_file, [filename(State), contents()]},
             {call, ?MODULE, delete_file, [filename(State)]}]
    end,
    oneof(Calls).

%% @doc Determines whether a command should be valid under the
%% current state.
precondition(State, {call, _, add_file, [Filename, _Contents]}) ->
    not maps:is_key(Filename, State) andalso not_is_dir(Filename, State);
precondition(State, {call, _, change_file, [Filename, Contents]}) ->
    case maps:find(Filename, State) of
        error ->
            false;
        {ok, {_Hash, Contents}} ->
            false;
        {ok, {_Hash, _OldContents}} ->
            true
    end;
precondition(State, {call, _, delete_file, [Filename]}) ->
    maps:is_key(Filename, State);
precondition(_State, {call, _Mod, _Fun, _Args}) ->
    true.

%% @doc Given the state `State' *prior* to the call
%% `{call, Mod, Fun, Args}', determine whether the result
%% `Res' (coming from the actual system) makes sense.
postcondition(_State, {call, _, add_file, _}, ok) ->
    true;
postcondition(_State, {call, _, change_file, _}, ok) ->
    true;
postcondition(_State, {call, _, delete_file, _}, ok) ->
    true;
postcondition(State, {call, _, rescan, [_, _]}, Ret) ->
    {ExpDel, ExpAdd, ExpMod} = merge_ops(
        [{Op, {filename:join(F),H}} || {Op, {F,H}} <- maps:get(ops, State)],
        maps:get(set, State)
    ),
    ExpSet = lists:sort(
        [{filename:join(File), Hash}
         || {File, {Hash, _}} <- maps:to_list(State), not is_atom(File)]
    ),
    Res = {{ExpDel, ExpAdd, ExpMod}, ExpSet} =:= Ret,
    Res orelse io:format("===~n~p~n---~n~p~n===~n",
                         [{{ExpDel, ExpAdd, ExpMod}, ExpSet}, Ret]),
    Res;
postcondition(_State, {call, _Mod, _Fun, _Args}, _Res) ->
    false.

%% @doc Assuming the postcondition for a call was true, update the model
%% accordingly for the test to proceed.
next_state(State, _Res, {call, _, add_file, [FileName, Contents]}) ->
    Hash = crypto:hash(sha256, Contents),
    Dirs = maps:get(dirs, State),
    Path = lists:droplast(FileName),
    State#{FileName => {Hash, Contents},
           dirs => lists:usort([Path|Dirs])--[[]],
           ops => [{add, {FileName, Hash}} | maps:get(ops, State)]};
next_state(State, _Res, {call, _, change_file, [FileName, Contents]}) ->
    Hash = crypto:hash(sha256, Contents),
    State#{FileName => {Hash, Contents},
           ops => [{change, {FileName, Hash}} | maps:get(ops, State)]};
next_state(State, _Res, {call, _, delete_file, [FileName]}) ->
    {Hash, _} = maps:get(FileName, State),
    NewState = maps:remove(FileName, State),
    NewState#{ops => [{delete, {FileName, Hash}} | maps:get(ops, State)]};
next_state(State, Res, {call, _, rescan, [_, _]}) ->
    %% Symbolic call to work around the symbolic execution issues
    %% without having to wrap the rescan calls furthermore.
    State#{set := {call, erlang, element, [2, Res]},
           ops => []};
next_state(State, _Res, {call, _Mod, _Fun, _Args}) ->
    NewState = State,
    NewState.

%%%%%%%%%%%%%%%%%%
%%% GENERATORS %%%
%%%%%%%%%%%%%%%%%%
new_filename(Map) ->
    ?SUCHTHAT(
       Path,
       ?LET(Base, revault_test_utils:gen_path(),
            filename:split(filename:join(?DIR, Base))),
       not_is_dir(Path, Map)
    ).

not_is_dir(Path, Map) ->
    lists:all(
        fun(ExistingDir) -> not lists:prefix(Path, ExistingDir) end,
        maps:get(dirs, Map)
    )
    andalso
    lists:all(
        fun(Existing) -> not lists:prefix(Existing, Path) end,
        [K || K <- maps:keys(Map), not is_atom(K)]
    ).

filename(Map) ->
    oneof([P || P <- maps:keys(Map), not is_atom(P)]).

contents() ->
    binary().

%%%%%%%%%%%%%%%%%%%
%%% MODEL CALLS %%%
%%%%%%%%%%%%%%%%%%%
add_file(FileName, Contents) ->
    Path = filename:join(FileName),
    filelib:ensure_dir(Path),
    file:write_file(Path, Contents, [sync, raw]).

change_file(FileName, Contents) ->
    file:write_file(filename:join(FileName), Contents, [sync, raw]).

delete_file(FileName) ->
    file:delete(filename:join(FileName)).

%%%%%%%%%%%%%%%
%%% HELPERS %%%
%%%%%%%%%%%%%%%
merge_ops(Ops, InitSet) ->
    Map = maps:from_list([{File, {Op, Hash}}
                          || {Op, {File, Hash}} <- lists:reverse(Ops)]),
    process_ops(Map, InitSet).

process_ops(Map, InitSet) ->
    {Del, Add, Mod} = maps:fold(
        fun(File, Ops, {Del, Add, Mod}) ->
            Init = proplists:get_value(File, InitSet),
            case {Ops, Init} of
                %% unchanged over both polls
                {{delete, _Hash}, undefined} ->
                    {Del, Add, Mod};
                %% deleted file
                {{delete, _Hash}, OldHash} ->
                    {[{File, OldHash}|Del], Add, Mod};
                %% sequence ended in added file
                {{_, Hash}, undefined} ->
                    {Del, [{File, Hash}|Add], Mod};
                %% changes had no impact
                {{_, Hash}, Hash} ->
                    {Del, Add, Mod};
                %% sequence ended in changed file
                {{_, Hash}, _} ->
                    {Del, Add, [{File, Hash}|Mod]}
            end
        end,
        {[], [], []},
        Map
    ),
    {lists:sort(Del), lists:sort(Add), lists:sort(Mod)}.

