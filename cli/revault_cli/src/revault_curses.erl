-module(revault_curses).
-include("revault_cli.hrl").
-include_lib("cecho/include/cecho.hrl").
-export([start_link/1, send_input/2, send_event/2]).
-export([init/1]).
-export([parse_list/2, check_connect/2]).
-export([clear_status/1, set_status/2]).

-type menu_key() :: atom().
-type val_type() :: {type_name(), convertor(), validator()}.
-type type_name() :: node | string | list.
-type convertor() :: regex() | convertor_fun().
-type regex() :: string().
-type convertor_fun() :: fun((string(), state()) -> {ok, term(), state()} | {error, term()}).
-type validator() :: fun((state(), term()) -> ok | {error, term()}).
-type render_mode() :: raw | clip | {clip, pos()} | wrap.
-type pos() :: {y(), x()}.
-type y() :: non_neg_integer().
-type x() :: non_neg_integer().
-type max_lines() :: pos_integer().
-type max_cols() :: pos_integer().
-type line() :: string().
-type lines() :: [line()].
-type arg() :: #{name := menu_key(),
                 label := string(),
                 help := string(),
                 default := term(),
                 type := val_type()}.
-type exec_arg() :: #{type_name() := term()}.
%% TODO: split internal state from callback state
-type nstate() :: #{mode := menu | action | exec,
                    menu := menu_key() | undefined,
                    hover_menu := menu_key(),
                    menu_map => #{menu_key() => pos()},
                    menu_coord_map => #{pos() => menu_key()},
                    action_args := [[arg(), ...], ...],
                    state := state(),
                    action_coords => {pos(), pos()},
                    exec_coords => {pos(), pos()},
                    status_coords => {pos(), pos()},
                    status_init_pos => pos(),
                    status_message => iodata()}.
-type state() :: term().

-callback menu_order() -> [menu_key(), ...].
-callback menu_help(menu_key()) -> string().
-callback args() -> #{menu_key() := [arg(), ...]}.
-callback init() -> state().
-callback render_exec(menu_key(), exec_arg(), max_lines(), max_cols(), state()) ->
            {render_mode(), state(), lines()}.
-callback handle_exec(input, integer(), menu_key(), state()) -> {ok | done, state()};
                     (event, term(), menu_key(), state()) -> {ok | done, state()}.

%%%%%%%%%%%%%%%%%
%%% LIFECYCLE %%%
%%%%%%%%%%%%%%%%%
start_link(Module) ->
    supervisor_bridge:start_link(?MODULE, Module).

send_input(Pid, Char) ->
    Pid ! {input, Char}.

send_event(Pid, Event) ->
    Pid ! {event, Event}.

init(Module) ->
    Pid = spawn_link(fun() -> main(Module) end),
    {ok, Pid, Module}.

-spec main(module()) -> no_return().
main(Module) ->
    setup(),
    State = state(Module, #{}),
    cecho:refresh(),
    Pid = self(),
    spawn_link(fun F() ->
        Pid ! {input, cecho:getch()},
        F()
    end),
    loop(Module, select_menu(State, maps:get(hover_menu, State))).

setup() ->
    logger:remove_handler(default),
    %% go in character-by-charcter mode
    cecho:cbreak(),
    %% don't show output
    cecho:noecho(),
    %% give keypad access
    cecho:keypad(?ceSTDSCR, true),
    %% don't wait on ESC keys
    cecho:set_escdelay(25),
    %% initial cursor position
    cecho:move(1,1),
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% STATE AND DISPLAY MANAGEMENT %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
state(Mod, Old) ->
    Default = #{
        mode => menu,
        hover_menu => hd(Mod:menu_order()),
        menu => undefined,
        state => Mod:init()
    },
    Tmp0 = maps:merge(Default, Old),
    %% Refresh the layout to show proper coordinates
    Tmp1 = show_menu(Mod, Tmp0),
    Tmp2 = show_action(Mod, Tmp1),
    Tmp3 = show_exec(Mod, Tmp2),
    Tmp4 = end_table(Mod, Tmp3),
    cecho:refresh(),
    Tmp4.

show_menu(Mod, State) ->
    #{menu := Chosen, hover_menu := Hover, mode := Mode} = State,
    MenuOrder = Mod:menu_order(),
    StringMenu = [atom_to_list(X) || X <- MenuOrder],
    TopRow = ["╔═",
              lists:join("═╤═", [lists:duplicate(string:length(X), "═") || X <- StringMenu]),
              "═╗"],
    MenuRow = ["║ ", lists:join(" │ ", [format_menu(X, Chosen) || X <- StringMenu]), " ║"],
    BottomRow = ["╟─",
                 lists:join("─┴─", [lists:duplicate(string:length(X), "─") || X <- StringMenu]),
                 "─╢"],
    {_, MenuMap, CoordMap} = lists:foldl(
        fun(X, {N,M,C}) ->
            XStr = atom_to_list(X),
            {N+length(XStr)+3,
            M#{X => {1,N}},
            C#{{1,N} => X}}
        end,
        {2, #{}, #{}},
        MenuOrder
    ),
    Width = string:length(MenuRow)-1,
    str(0, 0, TopRow),
    str(1, 0, MenuRow),
    str(2, 0, BottomRow),
    NewState = State#{menu_coords => {{0,0}, {2,Width}},
                      menu_map => MenuMap,
                      menu_coord_map => CoordMap,
                      menu_init_pos => {1,2}},
    %% set cursor if in menu mode and show help for hovered item
    case {Mode, Hover} of
        {menu, Hover} ->
            MoveTo = menu_pos(NewState, Hover),
            mv(MoveTo),
            set_status(NewState, Mod:menu_help(Hover));
        _ ->
            NewState
    end.

show_action(_Mod, State = #{mode := Mode,
                            menu_coords := {_, End}}) when Mode == menu ->
    State#{action_coords => {End, End}};
show_action(Mod, State = #{mode := Mode, menu := Action,
                           menu_coords := {_, {MenuY, MaxX}}}) when Mode == action;
                                                                    Mode == exec ->
    MinY = MenuY,
    %% TODO: clip lines that are too long
    {ArgState, Args} = arg_output(State, Action,
                                  maps:get(action_args, State,
                                           maps:get(Action, Mod:args(), []))),
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
    CurrentY = case cecho:getyx() of
        {CurY, CurX} when CurY >= MinY, CurY =< MaxY,
                          CurX >= 2, CurX =< MaxX ->
            CurY;
        _ ->
            %% Outside the box, move it to a known location
            case Ranges of
                [] ->
                    mv({MinY, 2}),
                    MinY;
                [#{range := {First, _Last}}|_] ->
                    mv(First),
                    element(1, First)
            end
    end,
    {ExtraLines, TmpState} = case Mode of
        action ->
            NthArg = CurrentY - MinY,
            #{help := Help} = lists:nth(NthArg, Args),
            {0, maybe_set_status(ArgState, Help)}; % this is the last section
        _ ->
            %% terminate table section
            BottomRow = ["╟", lists:duplicate(MaxX-1, "─"), "╢"],
            str(MaxY+1, 0, BottomRow),
            {1, ArgState}
    end,
    TmpState#{action_coords => {{MinY,0}, {MaxY+ExtraLines,MaxX}},
              action_args => Ranges,
              action_init_pos => {MinY, 2}}.

show_exec(_Mod, State=#{mode := Mode,
                  action_coords := {_, {Y,X}}}) when Mode =/= exec ->
    State#{exec_coords => {{Y,0},{Y,X}}};
show_exec(Mod, State=#{mode := exec,
                       menu := Action,
                       action_coords := {_, {ActionY,MaxX}},
                       action_args := Args,
                       state := ModState}) ->
    MinY = ActionY,
    %% expect line-based output in a list
    MaxLines = ?EXEC_LINES,
    MaxCols = MaxX-4,
    MaxY = MinY + MaxLines,
    ModArgs = maps:from_list([{N, V} || #{name := N, val := V} <- Args]),
    {RenderMode, NewModState, Lines} = Mod:render_exec(Action, ModArgs, MaxLines, MaxCols, ModState),
    case RenderMode of
        raw ->
            render_raw(Lines, {MinY,0}, {MaxY, MaxX});
        wrap ->
            render_raw(wrap(Lines, MaxLines, MaxCols),
                       {MinY,0}, {MaxY, MaxX});
        clip ->
            render_raw(clip(Lines, {0,0}, MaxLines, MaxCols),
                           {MinY,0}, {MaxY, MaxX});
        {clip, Offsets} ->
            render_raw(clip(Lines, Offsets, MaxLines, MaxCols),
                            {MinY,0}, {MaxY, MaxX})
    end,
    State#{exec_coords => {{MinY,0},{MaxY,MaxX}},
           state => NewModState}.

end_table(_Mod, State=#{exec_coords := {_, {Y,X}}}) ->
    str(Y+1, 0, ["╚", lists:duplicate(X-1, "═") ,"╝"]),
    str(Y+2, 0, "  ╰─ "),
    %% Clear status area and render status if present
    {StatusY, StatusX} = {Y+2, 5},
    %% Clear the entire status line
    {MaxY,MaxX} = cecho:getmaxyx(),
    [str(LY, StatusX, lists:duplicate(MaxX-StatusX, $\s)) || LY <- lists:seq(StatusY,MaxY)],
    %% Render status message if present
    case State of
        #{status_message := StatusMsg} ->
            str(StatusY, StatusX, StatusMsg);
        _ ->
            ok
    end,
    State#{status_coords => {{Y+1,0}, {StatusY,StatusX}},
           status_init_pos => {StatusY,StatusX}}.

render_raw(Lines, {MinY, MinX}, {MaxY, MaxX}) ->
    LinesY = lists:foldl(fun(Line, Y) ->
        str(Y+1, MinX, ["║ ", string:pad(Line, MaxX-MinX-3), " ║"]),
        Y+1
    end, MinY, Lines),
    [str(LineY, MinX, ["║", lists:duplicate(MaxX-MinX-1, " "), "║"])
    || LineY <- lists:seq(LinesY+1, MaxY)].

select_menu(State, Menu) ->
    mv(menu_pos(State, Menu)),
    State#{hover_menu => Menu}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% STATE AND DISPLAY HELPERS %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
format_menu(X, Chosen) ->
    case atom_to_list(Chosen) of
        X -> string:uppercase(X);
        _ -> X
    end.

menu_at(#{menu_coord_map := CoordMap}, Coord) ->
        #{Coord := Menu} = CoordMap,
        Menu.

menu_pos(#{menu_map := M}, Menu) ->
    #{Menu := Coord} = M,
    Coord.

enter_menu(State, Menu) ->
    State#{mode => action,
           menu => Menu}.

set_status(State, Str) ->
    State#{status_message => Str}.

maybe_set_status(State=#{status_message := _}, _) -> State;
maybe_set_status(State, Str) -> set_status(State, Str).

clear_status(State) ->
    maps:without([status_message], State).

wrap(Str, Lines, Width) ->
    wrap(Str, 0, Width, 0, Lines, [[]]).

wrap(_Str, Width, Width, Lines, Lines, Acc) ->
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

clip(Lines, {OffY, OffX}, MaxLines, MaxCols) ->
    [string:slice(S, OffX, MaxCols)
     || S <- lists:sublist(Lines, OffY+1, MaxLines)].

%%%%%%%%%%%%%%%%%%%%
%%% ARG HANDLING %%%
%%%%%%%%%%%%%%%%%%%%

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

check_connect(_State, Node) ->
    case connect_nonblocking(Node) of
        ok -> ok;
        timeout -> {error, timeout};
        _ -> {error, connection_failure}
    end.

connect_nonblocking(Node) ->
    timeout_call(?MAX_VALIDATION_DELAY, fun() -> connect(Node) end).

connect(Node) ->
    case net_kernel:connect_node(Node) of
        ignored -> {error, no_dist};
        false -> {error, connection_failed};
        true -> ok
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
arg_output(State, Action, [#{type := {node, _, Validator}, label := Label, val := NodeVal}=Arg|Args], Acc) ->
    Status = case Validator(State, NodeVal) of
        ok -> "ok";
        {error, partial_success} -> "?!";
        {error, timeout} -> "??";
        _ -> "!!"
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

%% Internal use functions using the above material
%% but used to check all arguments fit and can be converted
%% properly.
validate_args(State, Action, Args) ->
    %% Validate all the arguments
    {Errors, Status} = lists:foldl(
        fun(Arg = #{line := {_Label, Str}}, {Acc, S}) ->
            case parse_arg(State, Action, Arg, Str) of
                {ok, _, _} -> {Acc, S};
                {error, Reason, _} -> {[{Arg, Reason}|Acc], error}
            end
        end,
        {[], ok},
        Args
    ),
    case Status of
        error ->
            {error, Errors};
        ok ->
            {_Valid, Invalid} = convert_args(State, Args),
            case Invalid of
                [] ->
                    ok;
                Invalid ->
                    {error, Invalid}
            end
    end.

convert_args(State, Args) ->
    lists:foldl(
        fun(Arg = #{val := Val, type := {_,_,F}}, {V,I}) ->
            case F(State, Val) of
                ok -> {[Arg|V], I};
                {error, Reason} -> {V, [{Arg, Reason}]}
            end
        end,
        {[],[]},
        Args
    ).

%%%%%%%%%%%%%%%%%%%%%
%%% MAIN TUI LOOP %%%
%%%%%%%%%%%%%%%%%%%%%
-spec loop(module(), nstate()) -> no_return().
loop(Mod, OldState) ->
    State = #{mode := Mode} = state(Mod, OldState),
    case Mode of
        menu ->
            receive
                {input, Input} ->
                    {ok, NewState} = handle_menu(Mod, {input, Input}, State),
                    loop(Mod, NewState)
            end;
        action ->
            #{menu := Action} = State,
            receive
                {input, Input} ->
                    {ok, NewState} = handle_action({input, Input}, Action, clear_status(State)),
                    loop(Mod, NewState)
            end;
        exec ->
            #{menu := Action} = State,
            Msg = receive
                {input, Input} -> {input, Input};
                {event, Other} -> {event, Other}
            end,
            case handle_exec(Mod, Msg, Action, State) of
                {ok, NewState} ->
                    loop(Mod, NewState);
                {done, TmpState} ->
                    %% clear up the arg list and status messages
                    NewState = revault_curses:clear_status(TmpState#{mode => action}),
                    cecho:erase(),
                    loop(Mod, NewState)
            end
    end.


handle_menu(Mod, {input, Key}, TmpState) ->
    Pos = cecho:getyx(),
    case Key of
        ?ceKEY_RIGHT ->
            NewMenu = next(menu_at(TmpState, Pos), Mod:menu_order()),
            State = select_menu(TmpState, NewMenu),
            {ok, State};
        ?ceKEY_LEFT ->
            NewMenu = prev(menu_at(TmpState, Pos), Mod:menu_order()),
            State = select_menu(TmpState, NewMenu),
            mv_by({0,0}),
            {ok, State};
        $\n ->
            Menu = menu_at(TmpState, Pos),
            State = clear_status(enter_menu(TmpState, Menu)),
            {ok, State};
        UnknownChar ->
            State = set_status(
                TmpState,
                io_lib:format("Unknown menu character: ~w", [UnknownChar])
            ),
            {ok, State}
    end.

%% A little TUI editors for parameters.
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
    case validate_args(TmpState, Action, Args) of
        ok ->
            State = set_status(TmpState, "ok."),
            {ok, State#{mode => exec}};
        {error, [{#{line := {Label, _}}, Reason}|_]} ->
            State = set_status(
                TmpState,
                io_lib:format("Validation issue in ~ts: ~p", [Label, Reason])
            ),
            {ok, State}
    end;
handle_action({input, UnknownChar}, Action, TmpState) ->
    State = set_status(
        TmpState,
        io_lib:format("Unknown character in ~p: ~w", [Action, UnknownChar])
    ),
    {ok, State}.

handle_exec(Mod, {Type, Msg}, Action, State=#{state := ModState}) ->
    try
        {Key, NewModState} = Mod:handle_exec(Type, Msg, Action, ModState),
        {Key, State#{state => NewModState}}
    catch
        error:function_clause:Stack ->
        case Stack of
            [{Mod, handle_exec, _, _}|_] ->
                Status = case {Type, Msg} of
                    {input, Char} ->
                        io_lib:format("Unknown character in ~p: ~w", [Action, Char]);
                    {event, _Event} ->
                        io_lib:format("Got unexpected event in ~p: ~p", [Action, Msg])
                end,
                {ok, set_status(State, Status)};
            _ ->
                erlang:raise(error, function_clause, Stack)
        end
    end.

%%%%%%%%%%%%%%%%%%%%%%%
%%% NCURSES HELPERS %%%
%%%%%%%%%%%%%%%%%%%%%%%
str(Y, X, Str) ->
    {OrigY, OrigX} = cecho:getyx(),
    %% cecho expects a lists of bytes, so we gotta do some fun converting
    cecho:mvaddstr(Y, X, binary_to_list(unicode:characters_to_binary(Str))),
    cecho:move(OrigY, OrigX).

mv_by({OffsetY, OffsetX}) ->
    {CY, CX} = cecho:getyx(),
    cecho:move(CY+OffsetY, CX+OffsetX).

mv({Y,X}) ->
    cecho:move(Y, X).

%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% FUNCTIONAL HELPERS %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%
prev(K, L) -> next(K, lists:reverse(L)).

next(_, [N]) -> N;
next(K, [K,N|_]) -> N;
next(K, [_|T]) -> next(K, T).

replace([H|T], H, R) -> [R|T];
replace([H|T], S, R) -> [H|replace(T, S, R)].

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
