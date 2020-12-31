-module(prop_revault_id_fork_local).
-compile(export_all).
-include_lib("proper/include/proper.hrl").

prop_local(doc) ->
    "Test the ID forking mechanism locally; the logic of all calls being "
    "put in place and assumes a healthy and correct network".
prop_local() ->
    ?SETUP(fun() ->
            {ok, Apps} = application:ensure_all_started(gproc),
            fun() ->
                [application:stop(App) || App <- lists:reverse(Apps)],
                ok
            end
        end,
    ?FORALL(Cmds, proper_fsm:commands(?MODULE),
      ?TRAPEXIT(
        begin
            ShimState = id_shim:start_link(),
            {History,State,Result} = proper_fsm:run_commands(?MODULE, Cmds),
            id_shim:stop(ShimState),
            ?WHENFAIL(io:format("History: ~p\nState: ~p\nResult: ~p\n",
                                [History,State,Result]),
                      aggregate(zip(proper_fsm:state_names(History),
                                    command_names(Cmds)), 
                                Result =:= ok))
        end))).

-record(data, {
         client = #{id => undefined,
                    name => client},
         server = #{id => undefined,
                    name => server}
       }).

initial_state() -> undef.
%% Initial model data at the start. Should be deterministic.
initial_state_data() ->
    Id = revault_id:new(),
    #data{server = #{id => Id, name => server}}.

%% State commands generation
undef(#data{server = #{name := Server}, client = #{name := Client}}) ->
    [{waiting, {call, id_shim, id_ask, [Client, Server]}},
     {undef, {call, id_shim, inspect_id, [oneof([Client, Server])]}}].

waiting(#data{server = #{id := Id, name := Server}, client = #{name := Client}}) ->
    {_Keep, Send} = revault_id:fork(Id),
    [{done, {call, id_shim, id_reply, [Server, Client, Send]}},
     {waiting, {call, id_shim, inspect_id, [oneof([Client, Server])]}}].

done(#data{server = #{name := Server}, client = #{name := Client}}) ->
    [{done, {call, id_shim, inspect_id, [oneof([Client, Server])]}}].

%% Optional callback, weight modification of transitions
weight(_FromState, _ToState, {call, _, inspect_id, _}) -> 2;
weight(_FromState, _ToState, _Call) -> 1.

%% Picks whether a command should be valid.
precondition(_From, _To, #data{}, {call, _Mod, _Fun, _Args}) -> true.

%% Given the state states and data *prior* to the call `{call, Mod, Fun, Args}',
%% determine if the result `Res' (coming from the actual system) makes sense. 
postcondition(_From, _To, #data{client=#{name:=N, id:=Id}}, {call, _, inspect_id, [N]}, Res) ->
    Id =:= Res;
postcondition(_From, _To, #data{server=#{name:=N, id:=Id}}, {call, _, inspect_id, [N]}, Res) ->
    Id =:= Res;
postcondition(undef, waiting, #data{}, {call, _, id_ask, _}, Res) ->
    %% no reason for this to fail yet
    Res =:= ok;
postcondition(waiting, done, #data{}, {call, _, id_reply, _}, Res) ->
    %% No state to change here yet either, we'll detect it through inspection checks,
    %% just expect the call to have worked to get a state change.
    Res =:= ok;
postcondition(_From, _To, _Data, {call, _Mod, _Fun, _Args}, _Res) ->
    false.

%% Assuming the postcondition for a call was true, update the model
%% accordingly for the test to proceed. 
next_state_data(waiting, done, D=#data{client=C, server=S}, _Res, {call, _, id_reply, [_, _, Id]}) ->
    #{id := RootId} = S,
    {Keep, Send} = revault_id:fork(RootId),
    D#data{client = C#{id => Send}, server = S#{id => Keep}};
next_state_data(_From, _To, Data, _Res, {call, _Mod, _Fun, _Args}) ->
    NewData = Data,
    NewData.
