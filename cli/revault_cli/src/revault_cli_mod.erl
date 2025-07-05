-module(revault_cli_mod).
-behaviour(revault_curses).
-include("revault_cli.hrl").
-include_lib("cecho/include/cecho.hrl").

-define(DEFAULT_NODE, list_to_atom("revault@" ++ hd(tl(string:tokens(atom_to_list(node()), "@"))))).

-export([menu_order/0, menu_help/1, args/0,
         init/0, render_exec/5, handle_exec/4]).

%%%%%%%%%%%%%%%%%
%%% CALLBACKS %%%
%%%%%%%%%%%%%%%%%
menu_order() ->
    [list, scan, sync, status, 'generate-keys', seed, 'remote-seed'].

menu_help(list) -> "Show configuration and current settings";
menu_help(scan) -> "Scan directories for changes";
menu_help(sync) -> "Synchronize files with remote peer";
menu_help(status) -> "Display current ReVault instance's configuration status";
menu_help('generate-keys') -> "Generate TLS certificates for secure connections";
menu_help(seed) -> "Create initial seed data to a directory, to use in a client";
menu_help('remote-seed') -> "Create seed data as a client, from remote peer".

args() ->
    #{list => [
        #{name => node, label => "Local Node",
          type => {node, "[\\w.-]+@[\\w.-]+", fun check_connect/2}, default => ?DEFAULT_NODE,
          help => "ReVault instance to connect to"}
      ],
      scan => [
        #{name => node, label => "Local Node",
          type => {node, "[\\w.-]+@[\\w.-]+", fun check_connect/2}, default => ?DEFAULT_NODE,
          help => "Local ReVault instance to connect to"},
        #{name => dirs, label => "Dirs",
          type => {list, fun revault_curses:parse_list/2, fun check_dirs/2}, default => fun default_dirs/1,
          help => "List of directories to scan"}
      ],
      sync => [
        #{name => node, label => "Local Node",
          type => {node, "[\\w.-]+@[\\w.-]+", fun check_connect/2}, default => ?DEFAULT_NODE,
          help => "Local ReVault instance to connect to"},
        #{name => dirs, label => "Dirs",
          type => {list, fun revault_curses:parse_list/2, fun check_dirs/2}, default => fun default_dirs/1,
          help => "List of directories to scan"},
        #{name => peer, label => "Peer Node",
          type => {string, "^(?:\\s*)?(.+)(?:\\s*)?$", fun check_peer/2}, default => fun default_peers/1,
          help => "Peer to sync against"}
      ],
      status => [
        #{name => node, label => "Local Node",
          type => {node, "[\\w.-]+@[\\w.-]+", fun check_connect/2}, default => ?DEFAULT_NODE,
          help => "ReVault instance to connect to"}
      ],
      'generate-keys' => [
        #{name => certname, label => "Certificate Name",
          % the string regex 'trims' leading and trailing whitespace
          type => {string, "[^\\s]+.*[^\\s]+", fun check_ignore/2}, default => "revault",
          help => "Name of the key files generated"},
        #{name => path, label => "Certificate Directory",
          type => {string, "[^\\s]+.*[^\\s]+", fun check_ignore/2}, default => "./",
          help => "Directory where the key files will be placed"}
      ],
      seed => [
        #{name => node, label => "Local Node",
          type => {node, "[\\w.-]+@[\\w.-]+", fun check_connect/2}, default => ?DEFAULT_NODE,
          help => "ReVault instance to connect to"},
        #{name => path, label => "Fork Seed Directory",
          type => {string, "[^\\s]+.*[^\\s]+", fun check_ignore/2}, default => "./forked/",
          help => "path of the base directory where the forked data will be located."},
        #{name => dirs, label => "Dirs",
          type => {list, fun revault_curses:parse_list/2, fun check_dirs/2}, default => fun default_dirs/1,
          help => "List of directories to fork"}
        ],
      'remote-seed' => [
        #{name => node, label => "Local Node",
          type => {node, "[\\w.-]+@[\\w.-]+", fun check_connect/2}, default => ?DEFAULT_NODE,
          help => "ReVault instance to connect to"},
        #{name => peer, label => "Peer Node",
          type => {string, "^(?:\\s*)?(.+)(?:\\s*)?$", fun check_peer/2}, default => fun default_peers/1,
          help => "Peer from which to fork a seed"},
        #{name => dirs, label => "Dirs",
          %% TODO: replace list by 'peer_dirs'
          type => {list, fun revault_curses:parse_list/2, fun check_dirs/2}, default => fun default_dirs/1,
          help => "List of directories to fork"}
        ]
    }.

init() ->
    #{}.

render_exec(Action, Args, MaxLines, MaxCols, State) ->
    render_exec(Action, MaxLines, MaxCols, State#{exec_args => Args}).

render_exec(list, _MaxLines, _MaxCols, State) ->
    NewState = ensure_exec_state(list, State),
    #{exec_state := #{path := Path, config := Config, offset := {OffY,OffX}}} = NewState,
    Brk = io_lib:format("~n", []),
    Str = io_lib:format("Config parsed from ~ts:~n~p~n", [Path, Config]),
    %% Fit lines and the whole thing in a "box"
    Lines = string:lexemes(Str, Brk),
    {{clip, {OffY,OffX}}, NewState, Lines};
render_exec(scan, _MaxLines, _MaxCols, State) ->
    NewState = ensure_exec_state(scan, State),
    #{exec_state := #{dirs := Statuses}} = NewState,
    LStatuses = lists:sort(maps:to_list(Statuses)),
    %% TODO: support scrolling if you have more Dirs than MaxLines or
    %%       dirs that are too long by tracking clipping offsets.
    LongestDir = lists:max([string:length(D) || {D, _} <- LStatuses]),
    Strs = [[string:pad([Dir, ":"], LongestDir+1, trailing, " "), " ",
             case Status of
                 pending -> "??";
                 ok -> "ok";
                 _ -> "!!"
             end] || {Dir, Status} <- LStatuses],
    {clip, NewState, Strs};
render_exec(sync, _MaxLines, _MaxCols, State) ->
    NewState = ensure_exec_state(sync, State),
    #{exec_state := #{dirs := Statuses}} = NewState,
    LStatuses = lists:sort(maps:to_list(Statuses)),
    %% TODO: support scrolling if you have more Dirs than MaxLines or
    %%       dirs that are too long by tracking clipping offsets
    LongestDir = lists:max([string:length(D) || {D, _} <- LStatuses]),
    Header = [string:pad("DIR", LongestDir+1, trailing, " "), "  SCAN  SYNC"],
    Strs = [[string:pad([Dir, ":"], LongestDir+1, trailing, " "), " ",
             case Status of
                 pending -> "  ??";
                 scanned -> "  ok    ??";
                 synced  -> "  ok    ok";
                 _       -> "  !!    !!"
             end] || {Dir, Status} <- LStatuses],
    {clip, NewState, [Header | Strs]};
render_exec(status, _MaxLines, _MaxCols, State) ->
    NewState = ensure_exec_state(status, State),
    #{exec_state := #{status := Status}} = NewState,
    Strs = [io_lib:format("~p",[Status])],
    {wrap, NewState, Strs};
render_exec('generate-keys', _MaxLines, _MaxCols, State) ->
    NewState = ensure_exec_state('generate-keys', State),
    #{exec_state := #{status := Exists}} = NewState,
    {wrap, NewState, Exists};
render_exec(seed, _MaxLines, _MaxCols, State) ->
    NewState = ensure_exec_state(seed, State),
    #{exec_state := #{dirs := Statuses}} = NewState,
    LStatuses = lists:sort(maps:to_list(Statuses)),
    LongestDir = lists:max([string:length(D) || {D, _} <- LStatuses]),
    Strs = [[string:pad([Dir, ":"], LongestDir+1, trailing, " "), " ",
             case Status of
                 pending -> "??";
                 ok -> "ok";
                 _ -> "!!"
             end] || {Dir, Status} <- LStatuses],
    {clip, NewState, Strs};
render_exec('remote-seed', _MaxLines, _MaxCols, State) ->
    NewState = ensure_exec_state('remote-seed', State),
    #{exec_state := #{dirs := Statuses}} = NewState,
    LStatuses = lists:sort(maps:to_list(Statuses)),
    LongestDir = lists:max([string:length(D) || {D, _} <- LStatuses]),
    Strs = [[string:pad([Dir, ":"], LongestDir+1, trailing, " "), " ",
                case Status of
                    pending -> "??";
                    {ok, _ITC} -> "ok";
                    _ -> "!!"
                end] || {Dir, Status} <- LStatuses],
    {clip, NewState, Strs};
render_exec(Action, _MaxLines, _MaxCols, State) ->
    {clip, State, [[io_lib:format("Action ~p not implemented yet.", [Action])]]}.


handle_exec(input, ?ceKEY_ESC, _Action, State) ->
    %% TODO: clean up workers if any
    {done, maps:without([exec_state], State)};
%% List exec
handle_exec(input, ?ceKEY_DOWN, list, State = #{exec_state:=ES}) ->
    {Y,X} = maps:get(offset, ES, {0, 0}),
    {ok, State#{exec_state => ES#{offset => {Y+1, X}}}};
handle_exec(input, ?ceKEY_UP, list, State = #{exec_state:=ES}) ->
    {Y,X} = maps:get(offset, ES, {0, 0}),
    {ok, State#{exec_state => ES#{offset => {max(0,Y-1), X}}}};
handle_exec(input, ?ceKEY_RIGHT, list, State = #{exec_state:=ES}) ->
    {Y,X} = maps:get(offset, ES, {0, 0}),
    {ok, State#{exec_state => ES#{offset => {Y, X+1}}}};
handle_exec(input, ?ceKEY_LEFT, list, State = #{exec_state:=ES}) ->
    {Y,X} = maps:get(offset, ES, {0, 0}),
    {ok, State#{exec_state => ES#{offset => {Y, max(0,X-1)}}}};
handle_exec(input, ?ceKEY_PGDOWN, list, State = #{exec_state:=ES}) ->
    {Y,X} = maps:get(offset, ES, {0, 0}),
    Shift = ?EXEC_LINES-1,
    {ok, State#{exec_state => ES#{offset => {Y+Shift, X}}}};
handle_exec(input, ?ceKEY_PGUP, list, State = #{exec_state:=ES}) ->
    {Y,X} = maps:get(offset, ES, {0, 0}),
    Shift = ?EXEC_LINES-1,
    {ok, State#{exec_state => ES#{offset => {max(0,Y-Shift), X}}}};
%% TODO: ctrlA, ctrlE
%% Scan exec
handle_exec(event, {revault, scan, done}, scan, State=#{exec_state:=ES}) ->
    %% unset the workers
    case maps:get(worker, ES, undefined) of
        undefined ->
            ok;
        Pid ->
            %% make sure the worker is torn down fully, even
            %% if this is blocking
            Pid ! done,
            Ref = erlang:monitor(process, Pid),
            receive
                {'DOWN', Ref, process, _, _} ->
                    ok
            after 5000 ->
                %% we ideally wouldn't wait more than ?MAX_VALIDATION_DELAY
                %% so consider this a hard failure.
                error(bad_worker_shutdown)
            end
    end,
    {ok, State};
handle_exec(event, {revault, scan, {Dir, Status}}, scan, State=#{exec_state:=ES}) ->
    #{dirs := Statuses} = ES,
    {ok, State#{exec_state => ES#{dirs => Statuses#{Dir => Status}}}};
handle_exec(input, ?KEY_ENTER, scan, State) ->
    %% Do a refresh by exiting the menu and re-entering again. Quite hacky.
    revault_curses:send_event(self(), {revault, scan, done}),
    revault_curses:send_input(self(), ?ceKEY_ESC),
    revault_curses:send_input(self(), ?KEY_ENTER),
    {ok, State};
%% Sync exec
handle_exec(event, {revault, sync, done}, sync, State=#{exec_state:=ES}) ->
    %% unset the workers
    case maps:get(worker, ES, undefined) of
        undefined ->
            ok;
        Pid ->
            %% make sure the worker is torn down fully, even
            %% if this is blocking
            Pid ! done,
            Ref = erlang:monitor(process, Pid),
            receive
                {'DOWN', Ref, process, _, _} ->
                    ok
            after 5000 ->
                %% we ideally wouldn't wait more than ?MAX_VALIDATION_DELAY
                %% so consider this a hard failure.
                error(bad_worker_shutdown)
            end
    end,
    {ok, State};
handle_exec(event, {revault, sync, {Dir, Status}}, sync, State=#{exec_state:=ES}) ->
    #{dirs := Statuses} = ES,
    {ok, State#{exec_state => ES#{dirs => Statuses#{Dir => Status}}}};
handle_exec(input, ?KEY_ENTER, sync, State) ->
    %% Do a refresh by exiting the menu and re-entering again. Quite hacky.
    revault_curses:send_event(self(), {revault, sync, done}),
    revault_curses:send_input(self(), ?ceKEY_ESC),
    revault_curses:send_input(self(), ?KEY_ENTER),
    {ok, State};
%% Status
handle_exec(event, {revault, status, done}, status, State) ->
    {ok, State};
handle_exec(event, {revault, status, {ok, Val}}, status, State=#{exec_state:=ES}) ->
    {ok, State#{exec_state => ES#{status => Val}}};
handle_exec(input, ?KEY_ENTER, status, State) ->
    %% Do a refresh by exiting the menu and re-entering again. Quite hacky.
    revault_curses:send_event(self(), {revault, status, done}),
    revault_curses:send_input(self(), ?ceKEY_ESC),
    revault_curses:send_input(self(), ?KEY_ENTER),
    {ok, State};
%% Generate-Keys
handle_exec(event, {revault, 'generate-keys', {ok, Val}}, 'generate-keys', State=#{exec_state:=ES}) ->
    {ok, State#{exec_state => ES#{status => Val}}};
handle_exec(input, ?KEY_ENTER, 'generate-keys', State) ->
    %% Do a refresh by exiting the menu and re-entering again. Quite hacky.
    revault_curses:send_input(self(), ?ceKEY_ESC),
    revault_curses:send_input(self(), ?KEY_ENTER),
    {ok, State};
%% Seed exec
handle_exec(event, {revault, seed, done}, seed, State=#{exec_state:=ES}) ->
    %% unset the workers
    case maps:get(worker, ES, undefined) of
        undefined ->
            ok;
        Pid ->
            %% make sure the worker is torn down fully, even
            %% if this is blocking
            Pid ! done,
            Ref = erlang:monitor(process, Pid),
            receive
                {'DOWN', Ref, process, _, _} ->
                    ok
            after 5000 ->
                %% we ideally wouldn't wait more than ?MAX_VALIDATION_DELAY
                %% so consider this a hard failure.
                error(bad_worker_shutdown)
            end
    end,
    {ok, State};
handle_exec(event,{revault, seed, {Dir, Status}}, seed, State=#{exec_state:=ES}) ->
    #{dirs := Statuses} = ES,
    {ok, State#{exec_state => ES#{dirs => Statuses#{Dir => Status}}}};
%% remote-seed exec
handle_exec(event,{revault, 'remote-seed', done}, 'remote-seed', State=#{exec_state:=ES}) ->
    %% unset the workers
    case maps:get(worker, ES, undefined) of
        undefined ->
            ok;
        Pid ->
            %% make sure the worker is torn down fully, even
            %% if this is blocking
            Pid ! done,
            Ref = erlang:monitor(process, Pid),
            receive
                {'DOWN', Ref, process, _, _} ->
                    ok
            after 5000 ->
                %% we ideally wouldn't wait more than ?MAX_VALIDATION_DELAY
                %% so consider this a hard failure.
                error(bad_worker_shutdown)
            end
    end,
    {ok, State};
handle_exec(event,{revault, 'remote-seed', {Dir, Status}}, 'remote-seed', State=#{exec_state:=ES}) ->
    #{dirs := Statuses} = ES,
    file:write_file("/tmp/dbg", io_lib:format("~p~n", [{Dir, Status}])),
    {ok, State#{exec_state => ES#{dirs => Statuses#{Dir => Status}}}}.


%%%%%%%%%%%%%%%%%%%%
%%% ARGS HELPERS %%%
%%%%%%%%%%%%%%%%%%%%
default_dirs(#{local_node := Node}) ->
    try config(Node) of
        {config, _Path, Config} ->
            #{<<"dirs">> := DirMap} = Config,
            maps:keys(DirMap)
    catch
        _E:_R -> []
    end.

default_peers(State = #{local_node := Node}) ->
    DirList = maps:get(dir_list, State, []),
    try config(Node) of
        {config, _Path, Config} ->
            #{<<"peers">> := PeerMap} = Config,
            Needed = ordsets:from_list(DirList),
            Peers = [Peer
                     || Peer <- maps:keys(PeerMap),
                        Dirs <- [maps:get(<<"sync">>, maps:get(Peer, PeerMap))],
                        ordsets:is_subset(Needed, ordsets:from_list(Dirs))],
            %% Flatten into a string, since peer data espects a string.
            unicode:characters_to_binary(lists:join(", ", Peers))
    catch
        _E:_R -> []
    end.

check_connect(State, Node) ->
    case revault_curses:check_connect(State, Node) of
        ok ->
            case revault_node(Node) of
                ok -> ok;
                _ -> {error, partial_success}
            end;
        Error ->
            Error
    end.

check_dirs(#{local_node := Node}, Dirs) ->
    try config(Node) of
        {config, _Path, Config} ->
            #{<<"dirs">> := DirMap} = Config,
            ValidDirs = maps:keys(DirMap),
            case Dirs -- ValidDirs of
                [] -> ok;
                Others -> {error, {unknown_dirs, Others}}
            end
    catch
        E:R -> {error, {E,R}}
    end.

check_peer(State = #{local_node := Node}, Peer) ->
    DirList = maps:get(dir_list, State, []),
    try config(Node) of
        {config, _Path, Config} ->
            #{<<"peers">> := PeerMap} = Config,
            Peers = [ValidPeer
                     || ValidPeer <- maps:keys(PeerMap)],
            case lists:member(Peer, Peers) of
                true ->
                    Needed = ordsets:from_list(DirList),
                    PeerDirs = maps:get(<<"sync">>, maps:get(Peer, PeerMap, #{}), []),
                    case ordsets:is_subset(Needed, ordsets:from_list(PeerDirs)) of
                        true -> ok;
                        false -> {error, {mismatching_dirs, Peer, Needed, PeerDirs}}
                    end;
                false ->
                    {error, {unknown_peer, Peer, Peers}}
            end
    catch
        E:R -> {error, {E,R}}
    end.

check_ignore(_, _) ->
    ok.

-spec revault_node(atom()) -> ok | {error, term()}.
revault_node(Node) ->
    try erpc:call(Node, maestro_loader, status, []) of
        current -> ok;
        outdated -> ok;
        last_valid -> ok;
        _ -> {error, unknown_status}
    catch
        E:R -> {error, {rpc, {E,R}}}
    end.

config(Node) ->
    {ok, Path, Config} = erpc:call(Node, maestro_loader, current, []),
    {config, Path, Config}.

%%%%%%%%%%%%%%%%%%%%
%%% EXEC HELPERS %%%
%%%%%%%%%%%%%%%%%%%%
%% Helper function to ensure exec state is properly initialized
ensure_exec_state(list, State) ->
    case State of
        #{exec_state := #{path := _, config := _, offset := _}} ->
            State;
        #{exec_args := #{node := Node}} ->
            {ok, P, C} = erpc:call(Node, maestro_loader, current, []),
            State#{exec_state => #{path => P, config => C, offset => {0,0}}}
    end;
ensure_exec_state(scan, State) ->
    case State of
        #{exec_state := #{worker := _, dirs := _}} ->
            State;
        #{exec_args := Args} ->
            #{node := Node,
              dirs := Dirs} = Args,
            %% TODO: replace with an alias
            P = start_worker(self(), {scan, Node, Dirs}),
            DirStatuses = maps:from_list([{Dir, pending} || Dir <- Dirs]),
            State#{exec_state => #{worker => P, dirs => DirStatuses}}
    end;
ensure_exec_state(sync, State) ->
    case State of
        #{exec_state := #{worker := _, peer := _, dirs := _}} ->
            State;
        #{exec_args := Args} ->
            #{node := Node,
              peer := P,
              dirs := Dirs} = Args,
            %% TODO: replace with an alias
            W = start_worker(self(), {sync, Node, P, Dirs}),
            DirStatuses = maps:from_list([{Dir, pending} || Dir <- Dirs]),
            State#{exec_state => #{worker => W, peer => P, dirs => DirStatuses}}
    end;
ensure_exec_state(status, State) ->
    case State of
        #{exec_state := #{worker := _, status := _}} ->
            State;
        #{exec_args := #{node := Node}} ->
            %% TODO: replace with an alias
            P = start_worker(self(), {status, Node}),
            State#{exec_state => #{worker => P, status => undefined}}
    end;
ensure_exec_state('generate-keys', State) ->
    case State of
        #{exec_state := #{worker := _, status := _}} ->
            %% Do wrapping of the status line
            State;
        #{exec_args := Args} ->
            #{path := Path,
              certname := File} = Args,
            %% TODO: replace with an alias
            P = start_worker(self(), {generate_keys, Path, File}),
            State#{exec_state => #{worker => P, status => "generating keys..."}}
    end;
ensure_exec_state(seed, State) ->
    case State of
        #{exec_state := #{worker := _, dirs := _}} ->
            %% Do wrapping of the status line
            State;
        #{exec_args := Args} ->
            #{node := Node,
              path := Path,
              dirs := Dirs} = Args,
            %% TODO: replace with an alias
            P = start_worker(self(), {seed, Node, Path, Dirs}),
            DirStatuses = maps:from_list([{Dir, pending} || Dir <- Dirs]),
            State#{exec_state => #{worker => P, dirs => DirStatuses}}
    end;
ensure_exec_state('remote-seed', State) ->
    case State of
        #{exec_state := #{worker := _, peer := _, dirs := _}} ->
            %% Do wrapping of the status line
            State;
        #{exec_args := Args} ->
            #{node := Node,
              peer := P,
              dirs := Dirs} = Args,
            %% TODO: replace with an alias
            W = start_worker(self(), {'remote-seed', Node, P, Dirs}),
            DirStatuses = maps:from_list([{Dir, pending} || Dir <- Dirs]),
            State#{exec_state => #{worker => W, peer => P, dirs => DirStatuses}}
    end.

%%%%%%%%%%%%%%%%%%%%%
%%% ASYNC WORKERS %%%
%%%%%%%%%%%%%%%%%%%%%
start_worker(ReplyTo, Call) ->
    Parent = self(),
    spawn_link(fun() -> worker(Parent, ReplyTo, Call) end).

worker(Parent, ReplyTo, {scan, Node, Dirs}) ->
    worker_scan(Parent, ReplyTo, Node, Dirs);
worker(Parent, ReplyTo, {sync, Node, Peer, Dirs}) ->
    worker_sync(Parent, ReplyTo, Node, Peer, Dirs);
worker(Parent, ReplyTo, {status, Node}) ->
    worker_status(Parent, ReplyTo, Node);
worker(Parent, ReplyTo, {generate_keys, Path, File}) ->
    worker_generate_keys(Parent, ReplyTo, Path, File);
worker(Parent, ReplyTo, {seed, Node, Path, Dirs}) ->
    worker_seed(Parent, ReplyTo, Node, Path, Dirs);
worker(Parent, ReplyTo, {'remote-seed', Node, Peer, Dirs}) ->
    worker_remote_seed(Parent, ReplyTo, Node, Peer, Dirs).

worker_scan(Parent, ReplyTo, Node, Dirs) ->
    %% assume we are connected from arg validation time.
    %% We have multiple directories, so scan them in parallel.
    %% This requires setting up sub-workers, which incidentally lets us
    %% also listen for interrupts from the parent.
    process_flag(trap_exit, true),
    ReqIds = lists:foldl(fun(Dir, Ids) ->
        erpc:send_request(Node,
                          revault_dirmon_event, force_scan, [Dir, infinity],
                          Dir, Ids)
    end, erpc:reqids_new(), Dirs),
    worker_scan_loop(Parent, ReplyTo, Node, Dirs, ReqIds).

worker_scan_loop(Parent, ReplyTo, Node, Dirs, ReqIds) ->
    receive
        {'EXIT', Parent, Reason} ->
            %% clean up all the workers by being linked to them and dying
            %% an unclean death.
            exit(Reason);
        stop ->
            %% clean up all the workers by being linked to them and dying
            %% an unclean death.
            unlink(Parent),
            exit(shutdown)
    after 0 ->
        case erpc:wait_response(ReqIds, ?MAX_VALIDATION_DELAY, true) of
            no_request ->
                revault_curses:send_event(ReplyTo, {revault, scan, done}),
                exit(normal);
            no_response ->
                worker_scan_loop(Parent, ReplyTo, Node, Dirs, ReqIds);
            {{response, Res}, Dir, NewIds} ->
                revault_curses:send_event(ReplyTo, {revault, scan, {Dir, Res}}),
                worker_scan_loop(Parent, ReplyTo, Node, Dirs, NewIds)
        end
    end.

worker_sync(Parent, ReplyTo, Node, Peer, Dirs) ->
    %% assume we are connected from arg validation time.
    %% We have multiple directories, so sync them in parallel.
    %% This requires setting up sub-workers, which incidentally lets us
    %% also listen for interrupts from the parent.
    process_flag(trap_exit, true),
    ReqIds = lists:foldl(fun(Dir, Ids) ->
        erpc:send_request(Node,
                          revault_dirmon_event, force_scan, [Dir, infinity],
                          {scan, Dir}, Ids)
    end, erpc:reqids_new(), Dirs),
    worker_sync_loop(Parent, ReplyTo, Node, Peer, Dirs, ReqIds).

worker_sync_loop(Parent, ReplyTo, Node, Peer, Dirs, ReqIds) ->
    receive
        {'EXIT', Parent, Reason} ->
            %% clean up all the workers by being linked to them and dying
            %% an unclean death.
            exit(Reason);
        stop ->
            %% clean up all the workers by being linked to them and dying
            %% an unclean death.
            unlink(Parent),
            exit(shutdown)
    after 0 ->
        case erpc:wait_response(ReqIds, ?MAX_VALIDATION_DELAY, true) of
            no_request ->
                revault_curses:send_event(ReplyTo, {revault, sync, done}),
                exit(normal);
            no_response ->
                worker_sync_loop(Parent, ReplyTo, Node, Peer, Dirs, ReqIds);
            {{response, Res}, {scan, Dir}, TmpIds} ->
                Status = case Res of
                    ok -> scanned;
                    Other -> Other
                end,
                revault_curses:send_event(ReplyTo, {revault, sync, {Dir, Status}}),
                NewIds = erpc:send_request(
                    Node,
                    revault_fsm, sync, [Dir, Peer],
                    {sync, Dir},
                    TmpIds
                ),
                worker_sync_loop(Parent, ReplyTo, Node, Peer, Dirs, NewIds);
            {{response, Res}, {sync, Dir}, NewIds} ->
                Status = case Res of
                    ok -> synced;
                    Other -> Other
                end,
                revault_curses:send_event(ReplyTo, {revault, sync, {Dir, Status}}),
                worker_sync_loop(Parent, ReplyTo, Node, Peer, Dirs, NewIds)
        end
    end.

worker_status(Parent, ReplyTo, Node) ->
    process_flag(trap_exit, true),
    ReqIds = erpc:send_request(Node,
          maestro_loader, status, [],
    status, erpc:reqids_new()),
    worker_status_loop(Parent, ReplyTo,ReqIds).

worker_status_loop(Parent, ReplyTo, ReqIds) ->
    receive
        {'EXIT', Parent, Reason} ->
            exit(Reason);
        stop ->
            unlink(Parent),
            exit(shutdown)
    after 0 ->
        case erpc:wait_response(ReqIds, ?MAX_VALIDATION_DELAY, true) of
            no_request ->
                revault_curses:send_event(ReplyTo, {revault, status, done}),
                exit(normal);
            no_response ->
                worker_status_loop(Parent, ReplyTo, ReqIds);
            {{response, Res}, status, NewIds} ->
                revault_curses:send_event(ReplyTo, {revault, status, {ok, Res}}),
                worker_status_loop(Parent, ReplyTo, NewIds)
        end
    end.


worker_generate_keys(Parent, ReplyTo, Path, File) ->
    Res = make_selfsigned_cert(unicode:characters_to_list(Path),
                               unicode:characters_to_list(File)),
    %% we actually don't have a loop, everything is local
    %% and has already be run, so we just wait for a shutdown signal.
    revault_curses:send_event(ReplyTo, {revault, 'generate-keys', {ok, Res}}),
    receive
        {'EXIT', Parent, Reason} ->
            exit(Reason);
        stop ->
            unlink(parent),
            exit(shutdown)
    end.

worker_seed(Parent, ReplyTo, Node, Path, Dirs) ->
    %% assume we are connected from arg validation time.
    %% We have multiple directories, so scan them in parallel.
    %% This requires setting up sub-workers, which incidentally lets us
    %% also listen for interrupts from the parent.
    process_flag(trap_exit, true),
    ReqIds = lists:foldl(fun(Dir, Ids) ->
        erpc:send_request(Node,
                          revault_fsm, seed_fork, [Dir, Path],
                          Dir, Ids)
    end, erpc:reqids_new(), Dirs),
    worker_seed_loop(Parent, ReplyTo, Node, Dirs, ReqIds).

worker_seed_loop(Parent, ReplyTo, Node, Dirs, ReqIds) ->
    receive
        {'EXIT', Parent, Reason} ->
            %% clean up all the workers by being linked to them and dying
            %% an unclean death.
            exit(Reason);
        stop ->
            %% clean up all the workers by being linked to them and dying
            %% an unclean death.
            unlink(Parent),
            exit(shutdown)
    after 0 ->
        case erpc:wait_response(ReqIds, ?MAX_VALIDATION_DELAY, true) of
            no_request ->
                revault_curses:send_event(ReplyTo, {revault, seed, done}),
                exit(normal);
            no_response ->
                worker_seed_loop(Parent, ReplyTo, Node, Dirs, ReqIds);
            {{response, Res}, Dir, NewIds} ->
                revault_curses:send_event(ReplyTo, {revault, seed, {Dir, Res}}),
                worker_seed_loop(Parent, ReplyTo, Node, Dirs, NewIds)
        end
    end.

worker_remote_seed(Parent, ReplyTo, Node, Peer, Dirs) ->
    %% assume we are connected from arg validation time.
    %% We have multiple directories, so scan them in parallel.
    %% This requires setting up sub-workers, which incidentally lets us
    %% also listen for interrupts from the parent.
    process_flag(trap_exit, true),
    ReqIds = lists:foldl(fun(Dir, Ids) ->
        erpc:send_request(Node,
                          revault_fsm, id, [Dir, Peer],
                          Dir, Ids)
    end, erpc:reqids_new(), Dirs),
    worker_remote_seed_loop(Parent, ReplyTo, Node, Peer, Dirs, ReqIds).

worker_remote_seed_loop(Parent, ReplyTo, Node, Peer, Dirs, ReqIds) ->
    receive
        {'EXIT', Parent, Reason} ->
            %% clean up all the workers by being linked to them and dying
            %% an unclean death.
            exit(Reason);
        stop ->
            %% clean up all the workers by being linked to them and dying
            %% an unclean death.
            unlink(Parent),
            exit(shutdown)
    after 0 ->
        case erpc:wait_response(ReqIds, ?MAX_VALIDATION_DELAY, true) of
            no_request ->
                revault_curses:send_event(ReplyTo, {revault, 'remote-seed', done}),
                exit(normal);
            no_response ->
                worker_remote_seed_loop(Parent, ReplyTo, Node, Peer, Dirs, ReqIds);
            {{response, Res}, Dir, NewIds} ->
                revault_curses:send_event(ReplyTo, {revault, 'remote-seed', {Dir, Res}}),
                worker_remote_seed_loop(Parent, ReplyTo, Node, Peer, Dirs, NewIds)
        end
    end.

%%%%%%%%%%%%%%%%%%%
%%% EXTRA UTILS %%%
%%%%%%%%%%%%%%%%%%%

%% Copied from revault_tls
make_selfsigned_cert(Dir, CertName) ->
    check_openssl_vsn(),

    Key = filename:join(Dir, CertName ++ ".key"),
    Cert = filename:join(Dir, CertName ++ ".crt"),
    ok = filelib:ensure_dir(Cert),
    Cmd = io_lib:format(
        "openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes "
        "-keyout '~ts' -out '~ts' -subj '/CN=example.org' "
        "-addext 'subjectAltName=DNS:example.org,DNS:www.example.org,IP:127.0.0.1'",
        [Key, Cert] % TODO: escape quotes
    ),
    os:cmd(Cmd).

check_openssl_vsn() ->
    Vsn = os:cmd("openssl version"),
    VsnMatch = "(Open|Libre)SSL ([0-9]+)\\.([0-9]+)\\.([0-9]+)",
    case re:run(Vsn, VsnMatch, [{capture, all_but_first, list}]) of
        {match, [Type, Major, Minor, Patch]} ->
            try
                check_openssl_vsn(Type, list_to_integer(Major),
                                  list_to_integer(Minor),
                                  list_to_integer(Patch))
            catch
                error:bad_vsn ->
                    error({openssl_vsn, Vsn})
            end;
        _ ->
            error({openssl_vsn, Vsn})
    end.

%% Using OpenSSL >= 1.1.1 or LibreSSL >= 3.1.0
check_openssl_vsn("Libre", A, B, _) when A > 3;
                                         A == 3, B >= 1 ->
    ok;
check_openssl_vsn("Open", A, B, C) when A > 1;
                                        A == 1, B > 1;
                                        A == 1, B == 1, C >= 1 ->
    ok;
check_openssl_vsn(_, _, _, _) ->
    error(bad_vsn).
