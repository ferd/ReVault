#!/usr/bin/env escript
%%! -noinput -name ncurses_cli -setcookie revault_cookie
-mode(compile).
-include_lib("cecho/include/cecho.hrl").

%% Name of the main running host, as specified in `config/vm.args'
-define(DEFAULT_NODE, list_to_atom("revault@" ++ hd(tl(string:tokens(atom_to_list(node()), "@"))))).
-define(KEY_BACKSPACE, 127).
-define(KEY_CTRLA, 1).
-define(KEY_CTRLE, 5).
-define(KEY_CTRLD, 4).
-define(KEY_ENTER, 10).
-define(KEY_TEXT_RANGE(X), % ignore control codes
        (not(X < 32) andalso
         not(X >= 127 andalso X < 160))).

-define(EXEC_LINES, 15).
-define(MAX_VALIDATION_DELAY, 150). % longest time to validate input, in ms
-define(LOG(X),
        ok).
        %(fun() ->
        %    {ok, IoH} = file:open("/tmp/revaultlogcli", [append]),
        %    file:write(IoH, io_lib:format("~p~n", [X])),
        %    file:close(IoH)
        %end)()).


%%    0    0    1    1    2    2    3    3    4    4    5    5    6    6 6
%%    0    5    0    5    0    5    0    5    0    5    0    5    0    5 7
%%    ╔══════╤══════╤══════╤════════╤═══════════════╤══════╤═════════════╗
%%  1 ║ list │ scan │ SYNC │ status │ generate-keys │ seed │ remote-seed ║
%%    ╟──────┴──────┴──────┴────────┴───────────────┴──────┴─────────────╢
%%  3 ║ Local Node (ok): revault@node()                                  ║
%%  4 ║ Peer (X): …/peername                                             ║
%%  5 ║ Dirs: …/?/dir_a, dir_bigger, dir_c, dir_d                        ║
%%    ╟──────────────────────────────────────────────────────────────────╢
%%  7 ║               SCAN  SYNC                                         ║
%%    ║ dir_a:        ...   ...                                          ║
%%    ║ dir_bigger:   ok    ...                                          ║
%% 10 ║ dir_c:        ok    ok                                           ║
%%    ║ dir_d:        ok    X                                            ║
%%    ║                                                                  ║
%% 13 ╚══════════════════════════════════════════════════════════════════╝
%% 14   ╰─ some status
%%         even multi-line...

%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% CUSTOMIZING OPTIONS %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%
menu_order() ->
    [list, scan, sync, status, 'generate-keys', seed, 'remote-seed'].

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
          type => {list, fun parse_list/2, fun check_dirs/2}, default => fun default_dirs/1,
          help => "List of directories to scan"}
      ],
      sync => [
        #{name => node, label => "Local Node",
          type => {node, "[\\w.-]+@[\\w.-]+", fun check_connect/2}, default => ?DEFAULT_NODE,
          help => "Local ReVault instance to connect to"},
        #{name => dirs, label => "Dirs",
          type => {list, fun parse_list/2, fun check_dirs/2}, default => fun default_dirs/1,
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
          type => {list, fun parse_list/2, fun check_dirs/2}, default => fun default_dirs/1,
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
          type => {list, fun parse_list/2, fun check_dirs/2}, default => fun default_dirs/1,
          help => "List of directories to fork"}
        ]
    }.

parse_list(String, State) ->
    try
        %% drop surrounding whitespace and split on commas
        S = string:trim(String, both),
        L = re:split(S, "[\\s]*,[\\s]*", [{return, binary}, unicode]),
        %% ignore empty results (<<>>) in returned value
        {ok, [B || B <- L], State}
    catch
        _:_ -> {error, invalid, State}
    end.

parse_regex(Re, String, State) ->
    case re:run(String, Re, [{capture, first, binary}, unicode]) of
        {match, [Str]} -> {ok, Str, State};
        nomatch -> {error, invalid, State}
    end.

parse_with_fun(node, F, Str, State) ->
    maybe
        {ok, NewStr, NewState} ?= F(Str, State),
        Node = binary_to_atom(NewStr),
        {ok, Node, NewState}
    end;
parse_with_fun(_Type, F, Str, State) ->
    F(Str, State).

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

check_connect(_State, Node) ->
    case connect_nonblocking(Node) of
        ok ->
            case revault_node(Node) of
                ok -> ok;
                _ -> {error, non_revault_node}
            end;
        timeout ->
            {error, connection_timeout};
        _ ->
            {error, connection_failure}
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
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% DEFINING THE WHOLE UI THINGY %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
main(_) ->
    setup(),
    State = state(#{}),
    cecho:refresh(),
    Pid = self(),
    spawn_link(fun F() ->
        Pid ! {input, cecho:getch()},
        F()
    end),
    loop(select_menu(State, list)).

setup() ->
    logger:remove_handler(default),
    application:ensure_all_started(cecho),
    %% go in character-by-charcter mode
    cecho:cbreak(),
    %% don't show output
    cecho:noecho(),
    %% give keypad access
    cecho:keypad(?ceSTDSCR, true),
    %% initial cursor position
    cecho:move(1,1),
    ok.

state(Old) ->
    Default = #{
        mode => menu,
        hover_menu => hd(menu_order()),
        node => ?DEFAULT_NODE,
        connected => false,
        menu => undefined,
        peer => undefined,
        dirs => undefined,
        args => #{}
    },
    Tmp0 = maps:merge(Default, Old),
    %% Refresh the layout to show proper coordinates
    Tmp1 = show_menu(Tmp0),
    Tmp2 = show_action(Tmp1),
    Tmp3 = show_exec(Tmp2),
    Tmp4 = end_table(Tmp3),
    cecho:refresh(),
    Tmp4.


show_menu(State) ->
    #{menu := Chosen, hover_menu := Hover, mode := Mode} = State,
    StringMenu = [atom_to_list(X) || X <- menu_order()],
    TopRow = ["╔═",
              lists:join("═╤═", [lists:duplicate(string:length(X), "═")
                                || X <- StringMenu]),
              "═╗"],
    MenuRow = ["║ ", lists:join(" │ ", [format_menu(X, Chosen) || X <- StringMenu]), " ║"],
    BottomRow = ["╟─",
                 lists:join("─┴─", [lists:duplicate(string:length(X), "─")
                                   || X <- StringMenu]),
                 "─╢"],
    {_, MenuMap, CoordMap} = lists:foldl(
        fun(X, {N,M,C}) ->
            XStr = atom_to_list(X),
            {N+length(XStr)+3,
             M#{X => {1,N}},
             C#{{1,N} => X}}
        end,
        {2, #{}, #{}},
        menu_order()
    ),
    Width = string:length(MenuRow)-1,
    str(0, 0, TopRow),
    str(1, 0, MenuRow),
    str(2, 0, BottomRow),
    NewState = State#{menu_coords => {{0,0}, {2,Width}},
                      menu_map => MenuMap,
                      menu_coord_map => CoordMap,
                      menu_init_pos => {1,2}},
    %% set cursor if in menu mode
    case {Mode, Hover} of
        {menu, Hover} ->
            MoveTo = menu_pos(NewState, Hover),
            mv(MoveTo);
        _ ->
            ok
    end,
    NewState.

show_action(State = #{mode := Mode,
                      menu_coords := {_, End}}) when Mode == menu ->
    State#{action_coords => {End, End}};
show_action(State = #{mode := Mode, menu := Action,
                      menu_coords := {_, {MenuY, MaxX}}}) when Mode == action;
                                                               Mode == exec ->
    MinY = MenuY,
    %% TODO: truncate lines that are too long
    {ArgState, Args} = arg_output(State, Action,
                                  maps:get(action_args, State,
                                           maps:get(Action, args(), []))),
    MaxY = lists:foldl(fun(Arg, Y) ->
        #{line := {Label, Val}} = Arg,
        Line = [Label, ": ", Val],
        str(Y+1, 0, ["║ ", string:pad(Line, MaxX-3), " ║"]),
        Y+1
    end, MinY, Args),
    %% Ranges
    {_, RevRanges} = lists:foldl(fun(Arg, {Y, Acc}) ->
        #{line := {Label, _}} = Arg,
        {Y+1,
         [Arg#{range => {{Y+1, string:length(Label)+2+2}, {Y+1, MaxX-2}}} | Acc]}
    end, {MinY, []}, Args),
    Ranges = lists:reverse(RevRanges),
    %% Set position
    case cecho:getyx() of
        {CurY, CurX} when CurY >= MinY, CurY =< MaxY,
                          CurX >= 2, CurX =< MaxX ->
            ok;
        _ ->
            %% Outside the box, move it to a known location
            case Ranges of
                [] ->
                    mv({MinY, 2});
                [#{range := {First, _Last}}|_] ->
                    mv(First)
            end
    end,
    ExtraLines = case Mode of
        action ->
            0; % this is the last section
        _ ->
            %% terminate table section
            BottomRow = ["╟", lists:duplicate(MaxX-1, "─"), "╢"],
            str(MaxY+1, 0, BottomRow),
            1
    end,
    ArgState#{action_coords => {{MinY,0}, {MaxY+ExtraLines,MaxX}},
              action_args => Ranges,
              action_init_pos => {MinY, 2}}.

show_exec(State=#{mode := Mode,
                  action_coords := {_, {Y,X}}}) when Mode =/= exec ->
    State#{exec_coords => {{Y,0},{Y,X}}};
show_exec(State=#{mode := exec,
                  menu := Action,
                  action_coords := {_, {ActionY,MaxX}}}) ->
    MinY = ActionY,
    %% expect line-based output in a list
    MaxLines = ?EXEC_LINES,
    MaxCols = MaxX-4,
    {ExecState, Strs} = render_exec(Action, MaxLines, MaxCols, State),
    MaxY = MinY + MaxLines,
    LinesY = lists:foldl(fun(Line, Y) ->
        str(Y+1, 0, ["║ ", string:pad(Line, MaxX-3), " ║"]),
        Y+1
    end, MinY, Strs),
    [str(LineY, 0, ["║", lists:duplicate(MaxX-1, " "), "║"])
     || LineY <- lists:seq(LinesY+1, MaxY)],
    ExecState#{exec_coords => {{MinY,0},{MaxY,MaxX}}}.

end_table(State=#{exec_coords := {_, {Y,X}}}) ->
    str(Y+1, 0, ["╚", lists:duplicate(X-1, "═") ,"╝"]),
    str(Y+2, 0, "  ╰─ "),
    State#{status_coords => {{Y+1,0}, {Y+2,5}},
           status_init_pos => {Y+2,5}}.

show_status(State=#{status_init_pos := {Y,X},
                    menu_coords := {_, {_,Width}}},
            Str) ->
    {MaxY,_} = cecho:getmaxyx(),
    [str(LY, X, lists:duplicate(Width-X, $\s)) || LY <- lists:seq(Y,MaxY)],
    str(Y, X, Str),
    State.

loop(OldState) ->
    State = #{mode := Mode} = state(OldState),
    case Mode of
        menu ->
            receive
                {input, Input} ->
                    {ok, NewState} = handle_menu({input, Input}, State),
                    loop(NewState)
            end;
        action ->
            #{menu := Action} = State,
            receive
                {input, Input} ->
                    {ok, NewState} = handle_action({input, Input}, Action, State),
                    loop(NewState)
            end;
        exec ->
            #{menu := Action} = State,
            receive
                {input, Input} ->
                    {ok, NewState} = handle_exec({input, Input}, Action, State),
                    loop(NewState);
                {revault, Action, _} = Event ->
                    {ok, NewState} = handle_exec(Event, Action, State),
                    loop(NewState)
            end
    end.

handle_menu({input, Key}, TmpState) ->
    Pos = cecho:getyx(),
    case Key of
        ?ceKEY_RIGHT ->
            NewMenu = next(menu_at(TmpState, Pos), menu_order()),
            State = select_menu(TmpState, NewMenu),
            {ok, State};
        ?ceKEY_LEFT ->
            NewMenu = prev(menu_at(TmpState, Pos), menu_order()),
            State = select_menu(TmpState, NewMenu),
            mv_by({0,0}),
            {ok, State};
        $\n ->
            Menu = menu_at(TmpState, Pos),
            State = enter_menu(TmpState, Menu),
            show_status(State, io_lib:format("Entering ~p", [Menu])),
            {ok, State};
        UnknownChar ->
            State = show_status(
                TmpState,
                io_lib:format("Unknown menu character: ~w", [UnknownChar])
            ),
            {ok, State}
    end.

handle_action({input, ?ceKEY_ESC}, _Action, TmpState = #{menu := _Menu}) ->
    %% exit the menu
    TmpState2 = TmpState#{mode => menu, menu => undefined},
    %% clear up the arg list
    %% TODO: cache by action?
    State = maps:without([action_args], TmpState2),
    cecho:erase(),
    {ok, State};
handle_action({input, ?ceKEY_DOWN}, _Action, State = #{action_args := Args}) ->
    {Y,_} = cecho:getyx(),
    After = lists:dropwhile(fun(#{range := {_, {MaxY,_}}}) -> Y >= MaxY end, Args),
    case After of
        [#{range := {Pos, _}}|_] -> mv(Pos);
        _ -> ok
    end,
    {ok, State};
handle_action({input, ?ceKEY_UP}, _Action, State = #{action_args := Args}) ->
    {Y,_} = cecho:getyx(),
    Before = lists:takewhile(fun(#{range := {{MinY,_}, _}}) -> Y > MinY end, Args),
    case lists:reverse(Before) of
        [#{range := {Pos, _}}|_] -> mv(Pos);
        _ -> ok
    end,
    {ok, State};
handle_action({input, ?ceKEY_LEFT}, _Action, State = #{action_args := Args}) ->
    {Y,X} = cecho:getyx(),
    {value, #{range := {{_,MinX},_}}} = lists:search(
        fun(#{range := {{MinY,_}, {MaxY,_}}}) -> Y >= MinY andalso Y =< MaxY end,
        Args
    ),
    X > MinX andalso mv_by({0,-1}),
    {ok, State};
handle_action({input, ?ceKEY_RIGHT}, _Action, State = #{action_args := Args}) ->
    {Y,X} = cecho:getyx(),
    {value, #{range := {{_,MinX}, {_,MaxX}},
              line := {_, Str}}} = lists:search(
        fun(#{range := {{MinY,_}, {MaxY,_}}}) -> Y >= MinY andalso Y =< MaxY end,
        Args
    ),
    X < MaxX andalso X < MinX+string:length(Str) andalso mv_by({0,1}),
    {ok, State};
handle_action({input, ?KEY_CTRLA}, _Action, State = #{action_args := Args}) ->
    {Y,_} = cecho:getyx(),
    {value, #{range := {{_,MinX},_}}} = lists:search(
        fun(#{range := {{MinY,_}, {MaxY,_}}}) -> Y >= MinY andalso Y =< MaxY end,
        Args
    ),
    mv({Y, MinX}),
    {ok, State};
handle_action({input, ?KEY_CTRLE}, _Action, State = #{action_args := Args}) ->
    {Y,_} = cecho:getyx(),
    {value, #{range := {{_,MinX},_},
              line := {_, Str}}} = lists:search(
        fun(#{range := {{MinY,_}, {MaxY,_}}}) -> Y >= MinY andalso Y =< MaxY end,
        Args
    ),
    mv({Y,MinX+string:length(Str)}),
    {ok, State};
handle_action({input, ?KEY_BACKSPACE}, _Action, State = #{action_args := Args}) ->
    {Y,X} = cecho:getyx(),
    {value, Arg} = lists:search(
        fun(#{range := {{MinY,_}, {MaxY,_}}}) -> Y >= MinY andalso Y =< MaxY end,
        Args
    ),
    #{range := {{_,MinX},{_,MaxX}},
      line := {Label,Str}} = Arg,
    NewStr = case X > MinX of
        true -> % can go back
            Pre = string:slice(Str, 0, (X-MinX)-1),
            Post = string:slice(Str, X-MinX),
            Edited = [Pre,Post],
            str(Y, MinX, string:pad("", MaxX-MinX)),
            str(Y, MinX, Edited),
            mv_by({0,-1}),
            Edited;
        false ->
            Str
    end,
    NewArgs = replace(Args, Arg, Arg#{line => {Label,NewStr},
                                      unparsed => NewStr}),
    {ok, State#{action_args=>NewArgs}};
handle_action({input, ?ceKEY_DEL}, _Action, State = #{action_args := Args}) ->
    {Y,X} = cecho:getyx(),
    {value, Arg} = lists:search(
        fun(#{range := {{MinY,_}, {MaxY,_}}}) -> Y >= MinY andalso Y =< MaxY end,
        Args
    ),
    #{range := {{_,MinX},{_,MaxX}},
      line := {Label,Str}} = Arg,
    NewStr = case X >= MinX of
        true -> % can go back
            Pre = string:slice(Str, 0, X-MinX),
            Post = string:slice(Str, (X-MinX)+1),
            Edited = [Pre,Post],
            str(Y, MinX, string:pad("", MaxX-MinX)),
            str(Y, MinX, Edited),
            Edited;
        false ->
            Str
    end,
    NewArgs = replace(Args, Arg, Arg#{line => {Label,NewStr},
                                      unparsed => NewStr}),
    {ok, State#{action_args=>NewArgs}};
handle_action({input, ?KEY_CTRLD}, _Action, State = #{action_args := Args}) ->
    {Y,X} = cecho:getyx(),
    {value, Arg} = lists:search(
        fun(#{range := {{MinY,_}, {MaxY,_}}}) -> Y >= MinY andalso Y =< MaxY end,
        Args
    ),
    #{range := {{_,MinX},{_,MaxX}},
      line := {Label,Str}} = Arg,
    NewStr = case X >= MinX of
        true -> % can go back
            Edited = string:slice(Str, 0, X-MinX),
            str(Y, MinX, string:pad("", MaxX-MinX)),
            str(Y, MinX, Edited),
            Edited;
        false ->
            Str
    end,
    NewArgs = replace(Args, Arg, Arg#{line => {Label,NewStr},
                                      unparsed => NewStr}),
    {ok, State#{action_args=>NewArgs}};
handle_action({input, Char}, _Action, State = #{action_args := Args}) when ?KEY_TEXT_RANGE(Char) ->
    %% text input!
    {Y,X} = cecho:getyx(),
    {value, Arg} = lists:search(
        fun(#{range := {{MinY,_}, {MaxY,_}}}) -> Y >= MinY andalso Y =< MaxY end,
        Args
    ),
    #{range := {{_,MinX},{_,MaxX}},
      line := {Label,Str}} = Arg,
    NewStr = case X < MaxX andalso X >= MinX
                 andalso X =< MinX+string:length(Str) of
        true ->
            Pre = string:slice(Str, 0, X-MinX),
            Post = string:slice(Str, (X-MinX)),
            Edited = string:slice([Pre, Char, Post], 0, MaxX-MinX),
            str(Y, MinX, string:pad("", MaxX-MinX)),
            str(Y, MinX, Edited),
            mv_by({0,1}),
            Edited;
        false ->
            Str
    end,
    NewArgs = replace(Args, Arg, Arg#{line => {Label,NewStr},
                                      unparsed => NewStr}),
    {ok, State#{action_args=>NewArgs}};
handle_action({input, ?KEY_ENTER}, Action, TmpState = #{action_args := Args}) ->
    %% revalidate all values in all ranges; if any error
    %% is found, show it in the status line.
    %% if none are found, extract as clean options, and
    %% switch to execution mode.
    {Errors, Status} = lists:foldl(
        fun(Arg = #{line := {_Label, Str}}, {Acc, S}) ->
            case parse_arg(TmpState, Action, Arg, Str) of
                {ok, _, _} -> {Acc, S};
                {error, Reason, _} -> {[{Arg, Reason}|Acc], error}
            end
        end,
        {[], ok},
        Args
    ),
    case Status of
        ok ->
            {Valid, Invalid} = lists:foldl(
                fun(Arg = #{val := Val, type := {_,_,F}}, {V,I}) ->
                    case F(TmpState, Val) of
                        ok -> {[Arg|V], I};
                        {error, Reason} -> {V, [{Arg, Reason}]}
                    end
                end,
                {[],[]},
                Args
            ),
            case {Valid, Invalid} of
                {_, []} ->
                    %% TODO: change state to execution
                    State = show_status(TmpState, "ok."),
                    {ok, State#{mode => exec,
                                exec_args => Args}};
                {_, [{#{line := {Label, _}}, Reason}|_]} ->
                    State = show_status(
                        TmpState,
                        io_lib:format("Validation issue in ~ts: ~p", [Label, Reason])
                    ),
                    {ok, State}
            end;
        error ->
            [{#{line := {Label, _}}, Reason}|_] = Errors,
            State = show_status(
                TmpState,
                io_lib:format("Validation issue in ~ts: ~p", [Label, Reason])
            ),
            {ok, State}
    end;
handle_action({input, UnknownChar}, Action, TmpState) ->
    State = show_status(
        TmpState,
        io_lib:format("Unknown character in ~p: ~w", [Action, UnknownChar])
    ),
    {ok, State}.

handle_exec({input, ?ceKEY_ESC}, _Action, TmpState) ->
    %% clear up the arg list
    State = maps:without([exec_state], TmpState#{mode => action}),
    cecho:erase(),
    {ok, State};
%% List exec
handle_exec({input, ?ceKEY_DOWN}, list, State = #{exec_state:=ES}) ->
    {Y,X} = maps:get(offset, ES, {0, 0}),
    {ok, State#{exec_state => ES#{offset => {Y+1, X}}}};
handle_exec({input, ?ceKEY_UP}, list, State = #{exec_state:=ES}) ->
    {Y,X} = maps:get(offset, ES, {0, 0}),
    {ok, State#{exec_state => ES#{offset => {max(0,Y-1), X}}}};
handle_exec({input, ?ceKEY_RIGHT}, list, State = #{exec_state:=ES}) ->
    {Y,X} = maps:get(offset, ES, {0, 0}),
    {ok, State#{exec_state => ES#{offset => {Y, X+1}}}};
handle_exec({input, ?ceKEY_LEFT}, list, State = #{exec_state:=ES}) ->
    {Y,X} = maps:get(offset, ES, {0, 0}),
    {ok, State#{exec_state => ES#{offset => {Y, max(0,X-1)}}}};
handle_exec({input, ?ceKEY_PGDOWN}, list, State = #{exec_state:=ES}) ->
    {Y,X} = maps:get(offset, ES, {0, 0}),
    Shift = ?EXEC_LINES-1,
    {ok, State#{exec_state => ES#{offset => {Y+Shift, X}}}};
handle_exec({input, ?ceKEY_PGUP}, list, State = #{exec_state:=ES}) ->
    {Y,X} = maps:get(offset, ES, {0, 0}),
    Shift = ?EXEC_LINES-1,
    {ok, State#{exec_state => ES#{offset => {max(0,Y-Shift), X}}}};
%% TODO: ctrlA, ctrlE
%% Scan exec
handle_exec({revault, scan, done}, scan, State=#{exec_state:=ES}) ->
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
handle_exec({revault, scan, {Dir, Status}}, scan, State=#{exec_state:=ES}) ->
    #{dirs := Statuses} = ES,
    {ok, State#{exec_state => ES#{dirs => Statuses#{Dir => Status}}}};
handle_exec({input, ?KEY_ENTER}, scan, State) ->
    %% Do a refresh by exiting the menu and re-entering again. Quite hacky.
    self() ! {revault, scan, done},
    self() ! {input, ?ceKEY_ESC},
    self() ! {input, ?KEY_ENTER},
    {ok, State};
%% Sync exec
handle_exec({revault, sync, done}, sync, State=#{exec_state:=ES}) ->
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
handle_exec({revault, sync, {Dir, Status}}, sync, State=#{exec_state:=ES}) ->
    #{dirs := Statuses} = ES,
    {ok, State#{exec_state => ES#{dirs => Statuses#{Dir => Status}}}};
handle_exec({input, ?KEY_ENTER}, sync, State) ->
    %% Do a refresh by exiting the menu and re-entering again. Quite hacky.
    self() ! {revault, scan, done},
    self() ! {input, ?ceKEY_ESC},
    self() ! {input, ?KEY_ENTER},
    {ok, State};
%% Status
handle_exec({revault, status, done}, status, State) ->
    {ok, State};
handle_exec({revault, status, {ok, Val}}, status, State=#{exec_state:=ES}) ->
    {ok, State#{exec_state => ES#{status => Val}}};
handle_exec({input, ?KEY_ENTER}, status, State) ->
    %% Do a refresh by exiting the menu and re-entering again. Quite hacky.
    self() ! {revault, status, done},
    self() ! {input, ?ceKEY_ESC},
    self() ! {input, ?KEY_ENTER},
    {ok, State};
%% Generate-Keys
handle_exec({revault, 'generate-keys', {ok, Val}}, 'generate-keys', State=#{exec_state:=ES}) ->
    {ok, State#{exec_state => ES#{status => Val}}};
handle_exec({input, ?KEY_ENTER}, 'generate-keys', State) ->
    %% Do a refresh by exiting the menu and re-entering again. Quite hacky.
    self() ! {input, ?ceKEY_ESC},
    self() ! {input, ?KEY_ENTER},
    {ok, State};
%% Generic exec
handle_exec({input, UnknownChar}, Action, TmpState) ->
    State = show_status(
        TmpState,
        io_lib:format("Unknown character in ~p: ~w", [Action, UnknownChar])
    ),
    {ok, State};
handle_exec({revault, EventAct, Event}, Act, TmpState) ->
    State = show_status(
        TmpState,
        io_lib:format("Got unexpected ~p event in ~p: ~p", [EventAct, Act, Event])
    ),
    {ok, State};
handle_exec(Msg, Action, TmpState) ->
    State = show_status(
        TmpState,
        io_lib:format("Got unexpected message in ~p: ~p", [Action, Msg])
    ),
    {ok, State}.

mv_by({OffsetY, OffsetX}) ->
    {CY, CX} = cecho:getyx(),
    cecho:move(CY+OffsetY, CX+OffsetX).

mv({Y,X}) ->
    cecho:move(Y, X).

str(Y, X, Str) ->
    {OrigY, OrigX} = cecho:getyx(),
    %% cecho expects a lists of bytes, so we gotta do some fun converting
    cecho:mvaddstr(Y, X, binary_to_list(unicode:characters_to_binary(Str))),
    cecho:move(OrigY, OrigX).

prev(K, L) -> next(K, lists:reverse(L)).

next(_, [N]) -> N;
next(K, [K,N|_]) -> N;
next(K, [_|T]) -> next(K, T).

menu_at(#{menu_coord_map := CoordMap}, Coord) ->
    #{Coord := Menu} = CoordMap,
    Menu.

menu_pos(#{menu_map := M}, Menu) ->
    #{Menu := Coord} = M,
    Coord.

enter_menu(State, Menu) ->
    State#{mode => action,
           menu => Menu}.

select_menu(State, Menu) ->
    mv(menu_pos(State, Menu)),
    State#{hover_menu => Menu}.

format_menu(X, Chosen) ->
    case atom_to_list(Chosen) of
        X -> string:uppercase(X);
        _ -> X
    end.

arg_output(State, Action, Args) ->
    arg_output(State, Action, Args, []).

arg_output(State, _, [], Acc) ->
    {State, lists:reverse(Acc)};
arg_output(State, Action, [Arg|Args], Acc) when not is_map_key(val, Arg) ->
    {NewState, NewArg} = arg_init(State, Action, Arg),
    arg_output(NewState, Action, [NewArg|Args], Acc);
arg_output(State, Action, [Arg=#{unparsed := Unparsed}|Args], Acc) ->
    %% refresh data of pre-parsed elements.
    %% with the new value in place, apply the transformation to its internal
    %% format for further commands
    Ret = parse_arg(State, Action, Arg, Unparsed),
    %% Store it all!
    ?LOG({?LINE, parsed, maps:get(name, Arg), element(2, Ret)}),
    case Ret of
        {ok, Val, NewState} ->
            arg_output(NewState, Action,
                       [maps:without([line, unparsed], Arg#{val => Val}) | Args], Acc);
        {error, _Reason, NewState} ->
            %% TODO: update status?
            arg_output(NewState, Action, [maps:without([unparsed], Arg)|Args], Acc)
    end;
arg_output(State, Action, [Arg=#{line := _} | Args], Acc) ->
    arg_output(State, Action, Args, [Arg|Acc]);
arg_output(State, Action, [#{type := {node, _, _}, label := Label, val := NodeVal}=Arg|Args], Acc) ->
    Status = case connect_nonblocking(NodeVal) of
        ok ->
            case revault_node(NodeVal) of
                ok -> "ok";
                _ -> "?!"
            end;
        timeout ->
            "??";
        _ ->
            "!!"
    end,
    Line = {[Label, " (", Status, ")"], atom_to_list(NodeVal)},
    arg_output(State#{local_node => NodeVal}, Action,
               [Arg#{line => Line}|Args], Acc);
arg_output(State, Action, [#{name := dirs, type := {list, _, _}, label := Label, val := DirList}=Arg|Args], Acc) ->
    Line = {Label, lists:join(", ", DirList)},
    arg_output(State#{dir_list => DirList}, Action,
               [Arg#{line => Line}|Args], Acc);
arg_output(State, Action, [#{type := {list, _, _}, label := Label, val := List}=Arg|Args], Acc) ->
    Line = {Label, lists:join(", ", List)},
    arg_output(State, Action, [Arg#{line => Line}|Args], Acc);
arg_output(State, Action, [#{type := {string, _, _}, label := Label, val := Val}=Arg|Args], Acc) ->
    Line = {Label, Val},
    arg_output(State, Action, [Arg#{line => Line}|Args], Acc);
arg_output(State, Action, [#{type := Unsupported}=Arg|Args], Acc) ->
    #{label := Label} = Arg,
    Line = {io_lib:format("[Unsupported] ~ts", [Label]),
            io_lib:format("~p", [Unsupported])},
    arg_output(State, Action, [Arg#{line => Line}|Args], Acc).

arg_init(State, _Action, Arg = #{type := {node, _, _}, default := Default}) ->
    Val = maps:get(local_node, State, Default),
    {State#{local_node => Val}, Arg#{val => Val}};
arg_init(State, _Action, Arg = #{name := dirs, type := {list, _, _}, default := F}) ->
    Default = F(State),
    {State#{dir_list => Default}, Arg#{val => Default}};
arg_init(State, _Action, Arg = #{type := {list, _, _}, default := F}) ->
    {State, Arg#{val => F(State)}};
arg_init(State, _Action, Arg = #{type := {string, _, _}, default := X}) ->
    Default = if is_function(X, 1) -> X(State);
                 is_function(X) -> error(bad_arity);
                 true -> X
              end,
    {State, Arg#{val => Default}};
arg_init(State, _Action, Arg = #{type := Unsupported}) ->
    {State, Arg#{val => {error, Unsupported}}}.

parse_arg(State, _Action, #{type := TypeInfo}, Unparsed) ->
    case TypeInfo of
        {T, F, _Validation} when is_function(F) ->
            parse_with_fun(T, F, Unparsed, State);
        {T, Regex, _Validation} when is_list(Regex); is_binary(Regex) ->
            F = fun(String, St) -> parse_regex(Regex, String, St) end,
            parse_with_fun(T, F, Unparsed, State)
    end.

render_exec(list, MaxLines, MaxCols, State) ->
    {ok, Path, Config, {OffY,OffX}} = case State of
        #{exec_state := #{path := P, config := C, offset := Off}} ->
            {ok, P, C, Off};
        #{exec_args := Args} ->
            {value, #{val := Node}} = lists:search(fun(#{name := N}) -> N == node end, Args),
            {ok, P, C} = rpc:call(Node, maestro_loader, current, []),
            {ok, P, C, {0,0}}
    end,
    Brk = io_lib:format("~n", []),
    Str = io_lib:format("Config parsed from ~ts:~n~p~n", [Path, Config]),
    %% Fit lines and the whole thing in a "box"
    Lines = string:lexemes(Str, Brk),
    Truncated = [string:slice(S, OffX, MaxCols)
                 || S <- lists:sublist(Lines, OffY+1, MaxLines)],
    {State#{exec_state => #{path => Path, config => Config, offset => {OffY,OffX}}},
     Truncated};
render_exec(scan, MaxLines, MaxCols, State) ->
    {ok, Pid, Statuses} = case State of
        #{exec_state := #{worker := P, dirs := DirsStatuses}} ->
            {ok, P, DirsStatuses};
        #{exec_args := Args} ->
            self() ! init_scan,
            {value, #{val := Node}} = lists:search(fun(#{name := N}) -> N == node end, Args),
            {value, #{val := Dirs}} = lists:search(fun(#{name := N}) -> N == dirs end, Args),
            %% TODO: replace with an alias
            P = start_worker(self(), {scan, Node, Dirs}),
            DirStatuses = maps:from_list([{Dir, pending} || Dir <- Dirs]),
            {ok, P, DirStatuses}
    end,
    LStatuses = lists:sort(maps:to_list(Statuses)),
    %% TODO: support scrolling if you have more Dirs than MaxLines or
    %%       dirs that are too long.
    LongestDir = lists:max([string:length(D) || {D, _} <- LStatuses]),
    true = MaxLines >= length(LStatuses),
    true = MaxCols >= LongestDir + 4, % 4 chars for the status display room
    Strs = [[string:pad([Dir, ":"], LongestDir+1, trailing, " "), " ",
             case Status of
                 pending -> "??";
                 ok -> "ok";
                 _ -> "!!"
             end] || {Dir, Status} <- LStatuses],
    {State#{exec_state => #{worker => Pid, dirs => Statuses}}, Strs};
render_exec(sync, MaxLines, MaxCols, State) ->
    {ok, Pid, Peer, Statuses} = case State of
        #{exec_state := #{worker := W, peer := P, dirs := DirsStatuses}} ->
            {ok, W, P, DirsStatuses};
        #{exec_args := Args} ->
            self() ! init_scan,
            {value, #{val := Node}} = lists:search(fun(#{name := N}) -> N == node end, Args),
            {value, #{val := P}} = lists:search(fun(#{name := N}) -> N == peer end, Args),
            {value, #{val := Dirs}} = lists:search(fun(#{name := N}) -> N == dirs end, Args),
            %% TODO: replace with an alias
            W = start_worker(self(), {sync, Node, P, Dirs}),
            DirStatuses = maps:from_list([{Dir, pending} || Dir <- Dirs]),
            {ok, W, P, DirStatuses}
    end,
    LStatuses = lists:sort(maps:to_list(Statuses)),
    %% TODO: support scrolling if you have more Dirs than MaxLines or
    %%       dirs that are too long.
    LongestDir = lists:max([string:length(D) || {D, _} <- LStatuses]),
    true = MaxLines >= length(LStatuses),
    true = MaxCols >= LongestDir + 4, % 4 chars for the status display room
    Header = [string:pad("DIR", LongestDir+1, trailing, " "), "  SCAN  SYNC"],
    Strs = [[string:pad([Dir, ":"], LongestDir+1, trailing, " "), " ",
             case Status of
                 pending -> "  ??";
                 scanned -> "  ok    ??";
                 synced  -> "  ok    ok";
                 _       -> "  !!    !!"
             end] || {Dir, Status} <- LStatuses],
    {State#{exec_state => #{worker => Pid, peer => Peer, dirs => Statuses}},
     [Header | Strs]};
render_exec(status, _MaxLines, _MaxCols, State) ->
    {ok, Pid, Status} = case State of
        #{exec_state := #{worker := P, status := V}} ->
            {ok, P, V};
        #{exec_args := Args} ->
            self() ! init_scan,
            {value, #{val := Node}} = lists:search(fun(#{name := N}) -> N == node end, Args),
            %% TODO: replace with an alias
            P = start_worker(self(), {status, Node}),
            {ok, P, undefined}
    end,
    Strs = [io_lib:format("~p",[Status])],
    {State#{exec_state => #{worker => Pid, status => Status}}, Strs};
render_exec('generate-keys', MaxLines, MaxCols, State) ->
    {ok, Pid, Exists} = case State of
        #{exec_state := #{worker := P, status := Status}} ->
            %% Do wrapping of the status line
            {ok, P, Status};
        #{exec_args := Args} ->
            self() ! generate_keys,
            {value, #{val := Path}} = lists:search(fun(#{name := N}) -> N == path end, Args),
            {value, #{val := File}} = lists:search(fun(#{name := N}) -> N == certname end, Args),
            %% TODO: replace with an alias
            P = start_worker(self(), {generate_keys, Path, File}),
            {ok, P, "generating keys..."}
    end,
    Strs = wrap(Exists, MaxCols, MaxLines),
    {State#{exec_state => #{worker => Pid, status => Exists}}, Strs};
render_exec(Action, _MaxLines, _MaxCols, State) ->
    {State, [[io_lib:format("Action ~p not implemented yet.", [Action])]]}.

replace([H|T], H, R) -> [R|T];
replace([H|T], S, R) -> [H|replace(T, S, R)].

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% IMPLEMENTATION HELPERS %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

connect(Node) ->
    case net_kernel:connect_node(Node) of
        ignored -> {error, no_dist};
        false -> {error, connection_failed};
        true -> ok
    end.

connect_nonblocking(Node) ->
    timeout_call(?MAX_VALIDATION_DELAY, fun() -> connect(Node) end).

%% small helper that defers a blocking call that can be long
%% to another process, such that the validation step can have a
%% ceiling for how long it takes before returning a value.
%% If the process times out, it is killed brutally.
timeout_call(Timeout, Fun) ->
    P = self(),
    R = make_ref(),
    {Pid, Ref} = spawn_monitor(fun() ->
        Res = Fun(),
        P ! {R, Res}
    end),
    receive
        {R, Res} ->
            erlang:demonitor(R, [flush]),
            Res;
        {'DOWN', Ref, _, _, _} ->
            {error, connection_attempt_failed}
    after Timeout ->
        erlang:exit(Pid, kill),
        receive
            {'DOWN', Ref, _, _, _} ->
                timeout;
            {R, Res} ->
                erlang:demonitor(R, [flush]),
                Res
        end
    end.


-spec revault_node(atom()) -> ok | {error, term()}.
revault_node(Node) ->
    try rpc:call(Node, maestro_loader, status, []) of
        current -> ok;
        outdated -> ok;
        last_valid -> ok;
        _ -> {error, unknown_status}
    catch
        E:R -> {error, {rpc, {E,R}}}
    end.

config(Node) ->
    {ok, Path, Config} = rpc:call(Node, maestro_loader, current, []),
    {config, Path, Config}.

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
    worker_generate_keys(Parent, ReplyTo, Path, File).

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
                ReplyTo ! {revault, scan, done},
                exit(normal);
            no_response ->
                worker_scan_loop(Parent, ReplyTo, Node, Dirs, ReqIds);
            {{response, Res}, Dir, NewIds} ->
                ReplyTo ! {revault, scan, {Dir, Res}},
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
                ReplyTo ! {revault, sync, done},
                exit(normal);
            no_response ->
                worker_sync_loop(Parent, ReplyTo, Node, Peer, Dirs, ReqIds);
            {{response, Res}, {scan, Dir}, TmpIds} ->
                Status = case Res of
                    ok -> scanned;
                    Other -> Other
                end,
                ReplyTo ! {revault, sync, {Dir, Status}},
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
                ReplyTo ! {revault, sync, {Dir, Status}},
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
                ReplyTo ! {revault, status, done},
                exit(normal);
            no_response ->
                worker_status_loop(Parent, ReplyTo, ReqIds);
            {{response, Res}, status, NewIds} ->
                ReplyTo ! {revault, status, {ok, Res}},
                worker_status_loop(Parent, ReplyTo, NewIds)
        end
    end.


worker_generate_keys(Parent, ReplyTo, Path, File) ->
    Res = make_selfsigned_cert(unicode:characters_to_list(Path),
                               unicode:characters_to_list(File)),
    %% we actually don't have a loop, everything is local
    %% and has already be run, so we just wait for a shutdown signal.
    ReplyTo ! {revault, 'generate-keys', {ok, Res}},
    receive
        {'EXIT', Parent, Reason} ->
            exit(Reason);
        stop ->
            unlink(parent),
            exit(shutdown)
    end.

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

wrap(Str, Width, Lines) ->
    wrap(Str, 0, Width, 0, Lines, [[]]).

wrap(Str, Width, Width, Lines, Lines, Acc) ->
    lists:reverse(Acc);
wrap(Str, Width, Width, Ln, Lines, [L|Acc]) ->
    wrap(Str, 0, Width, Ln+1, Lines, [[],lists:reverse(L)|Acc]);
wrap(Str, W, Width, Ln, Lines, [L|Acc]) ->
    case string:next_grapheme(Str) of
        [Brk|Rest] when Brk == $\n; Brk == "\r\n" ->
            wrap(Rest, 0, Width, Ln+1, Lines, [[], lists:reverse(L)|Acc]);
        [C|Rest] ->
            wrap(Rest, W+1, Width, Ln, Lines, [[C|L]|Acc]);
        [] ->
            lists:reverse([lists:reverse(L)|Acc])
    end.
