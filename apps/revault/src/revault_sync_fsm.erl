%%% why not just use gen_statem here and use the callbacks directly
%%% in the tests? Lift what exists already
%%%
%%%         ,----------------------,
%%%         V  ,--> client --> {client, SubState}
%%%      idle -|
%%%         ^  '--> server --> {server, SubState}
%%%         '----------------------'
%%%
%%% should be given storage and access config...
-module(revault_sync_fsm).
-behaviour(gen_statem).
-export([start_link/4, start_link/5,
         server/1, client/1, id/1, id/2]).
-export([callback_mode/0,
         init/1, handle_event/4, terminate/3]).
-define(registry(M, N), {via, gproc, {n, l, {M, N}}}).
-define(registry(N), ?registry(?MODULE, N)).

-record(data, {
          db_dir,
          id,
          name,
          path,
          interval,
          callback :: module() | {module(), term()},
          remote
        }).

%  [dirs.images]
%  interval = 60
%  path = "/Users/ferd/images/"
%  ignore = [] # regexes on full path
start_link(DbDir, Name, Path, Interval) ->
    start_link(DbDir, Name, Path, Interval, revault_id_sync).

start_link(DbDir, Name, Path, Interval, Callback) ->
    gen_statem:start_link(?registry(Name), ?MODULE, {DbDir, Name, Path, Interval, Callback}, []).

server(Name) ->
    gen_statem:call(?registry(Name), {role, server}).

client(Name) ->
    gen_statem:call(?registry(Name), {role, client}).

id(Name) ->
    gen_statem:call(?registry(Name), id).

id(Name, Remote) ->
    gen_statem:call(?registry(Name), {id, Remote}).

callback_mode() ->
    [handle_event_function].

init({DbDir, Name, Path, Interval, Callback}) ->
    process_flag(trap_exit, true),
    Id = init_id(DbDir, Name),
    {ok, idle, #data{db_dir = DbDir,
                     id = Id,
                     name = Name,
                     path = Path,
                     interval = Interval,
                     callback = Callback}}.

%handle_event(EType, EContent, {client | server, State}, Data)

%% Idle State
handle_event({call, From}, {role, client}, idle, Data) ->
    {next_state, client, Data, [{reply, From, ok}]};
%handle_event({call, _}, {role, server}, idle, Data = #data{id = undefined}) ->
%    %% TODO: initialize the server ID as new? handled in server state.
%    {next_state, idle, Data, [{reply, {error, {id, undefined}}}]};
handle_event({call, From}, {role, server}, idle, Data) ->
    {next_state, server, Data, [{reply, From, ok}]};

%% Client Mode
handle_event({call, From}, id, client, Data=#data{id=Id}) ->
    {next_state, client, Data, [{reply, From, Id}]};
handle_event({call, _From}, {id, Remote}, client, Data = #data{id = undefined}) ->
    {next_state, {client, sync_id}, Data#data{remote=Remote},
      % get an ID from a server
     [{next_event, internal, sync_id},
      % enqueue the question and respond later
      postpone]};
handle_event({call, From}, {id, _Remote}, client, Data = #data{id = Id}) ->
    {next_state, client, Data, [{reply, From, {ok, Id}}]};
%% Getting a new ID
handle_event({call, _From}, {id, _Remote}, {client, sync_id}, Data) ->
    %% Not ready yet, defer until we got a response
    {keep_state, Data, [postpone]};
handle_event(internal, sync_id, {client, sync_id},
             Data = #data{id=undefined, remote=Remote, callback=Cb}) ->
    {AskPayload, NewCb} = apply_cb(Cb, ask, []),
    {_Ref, FinalCb} = apply_cb(NewCb, send, [Remote, AskPayload]),
    {keep_state, Data#data{callback=FinalCb}};
handle_event(info, {revault, _From, Payload}, {client, sync_id},
             Data=#data{name=Name, callback=Cb, db_dir=Dir}) ->
    {{reply, NewId}, NewCb} = apply_cb(Cb, unpack, [Payload]),
    ok = store_id(Dir, Name, NewId),
    %% TODO: forward the ID to handlers (or callers) to let them
    %%       start.
    {next_state, client, Data#data{id=NewId, callback=NewCb}};

%% Server Mode
handle_event({call, From}, id, server,
             Data=#data{id=undefined, name=Name, path=Path, interval=Interval,
                        callback=Cb, db_dir=DbDir}) ->
    {Id, NewCb} = apply_cb(Cb, new, []),
    ok = store_id(DbDir, Name, Id),
    {ok, _} = start_tracker(Name, Id, Path, Interval, DbDir),
    {next_state, server, Data#data{id=Id, callback=NewCb},
     [{reply, From, Id}]};
handle_event({call, From}, id, server, #data{id=Id}) ->
    {keep_state_and_data, [{reply, From, Id}]};
handle_event(info, {revault, From, Payload}, server,
             Data=#data{id=Id, name=Name, callback=Cb, db_dir=Dir}) ->
    io:format("~p ~n", [{received, From, Payload}]),
    {ask, Cb1} = apply_cb(Cb, unpack, [Payload]),
    {{NewId, NewPayload}, Cb2} = apply_cb(Cb1, fork, [Payload, Id]),
    %% Save NewId to disk before replying to avoid issues
    ok = store_id(Dir, Name, Id),
    %% TODO: Inject the new ID into all the local handlers before replying
    %%       to avoid concurrency issues
    {_, Cb3} = apply_cb(Cb2, reply, [From, NewPayload]),
    {next_state, server, Data#data{id=NewId, callback=Cb3}};

%% All-state
handle_event({call, From}, {role, _}, State, Data) when State =/= idle ->
    {next_state, State, Data, [{reply, From, {error, busy}}]}.

terminate(_State, _Data, _Reason) ->
    % end session
    ok.

%%% PRIVATE %%%
apply_cb({Mod, State}, F, Args) when is_atom(Mod) ->
    apply(Mod, F, Args ++ [State]);
apply_cb(Mod, F, Args) when is_atom(Mod) ->
    {apply(Mod, F, Args), Mod}.

init_id(Dir, Name) ->
    Path = filename:join([Dir, Name, "id"]),
    case file:read_file(Path) of
        {error, enoent} -> undefined;
        {ok, Bin} -> binary_to_term(Bin)
    end.

%% Callback-mode, Dir is the carried state.
store_id(Dir, Name, Id) ->
    Path = filename:join([Dir, Name, "id"]),
    PathTmp = filename:join([Dir, Name, "id.tmp"]),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(PathTmp, term_to_binary(Id)),
    ok = file:rename(PathTmp, Path).

start_tracker(Name, Id, Path, Interval, DbDir) ->
    revault_trackers_sup:start_tracker(Name, Id, Path, Interval, DbDir).
