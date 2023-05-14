%%% @doc
%%% Module in charge of running a server that monitors a given directory
%%% and forwards events related to all detected changes.
%%% The events are sent over the `gproc' property `{p, l, Name}', where
%%% `Name' is the name given to the server.
%%% @end
-module(revault_dirmon_event).
-export([start_link/2, force_scan/2, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {name :: term(),
                directory :: file:filename(),
                ignore :: revault_dirmon_poll:ignore(),
                poll_delay :: timeout(),
                poll_ref :: reference(),
                set :: revault_dirmon_poll:set()}).

%%%%%%%%%%%%%%%%%%
%%% PUBLIC API %%%
%%%%%%%%%%%%%%%%%%
start_link(Name, Opts) ->
    gen_server:start_link({via, gproc, {n, l, {?MODULE, Name}}}, ?MODULE,
                          Opts#{name => Name}, []).

-spec force_scan(term(), timeout()) -> ok.
force_scan(Name, Wait) ->
    gen_server:call({via, gproc, {n, l, {?MODULE, Name}}}, force_scan, Wait).

stop(Name) ->
    gen_server:stop({via, gproc, {n, l, {?MODULE, Name}}}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% GEN_SERVER CALLBACKS %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%
init(#{directory := Dir, poll_interval := Time, ignore := Ignore,
       name := Name, initial_sync := Mode}) ->
    {Set, Ref} = initial_sync(Mode, Name, Dir, Ignore, Time),
    {ok, #state{name = Name,
                directory = Dir,
                ignore = Ignore,
                poll_delay = Time,
                poll_ref = Ref,
                set = Set}}.

handle_call(force_scan, _From,
            S=#state{name=Name, directory=Dir, ignore=Ignore, set=Set}) ->
    {Updates, NewSet} = revault_dirmon_poll:rescan(Dir, Ignore, Set),
    send_events(Name, Updates),
    {reply, ok, S#state{set = NewSet}};
handle_call(_, _From, State) ->
    {noreply, State}.

handle_cast(_, State) ->
    {noreply, State}.

handle_info({timeout, TRef, poll}, S=#state{name=Name, directory=Dir,
                                            ignore=Ignore, set=Set,
                                            poll_delay=Time, poll_ref=TRef}) ->
    {Updates, NewSet} = revault_dirmon_poll:rescan(Dir, Ignore, Set),
    send_events(Name, Updates),
    NewRef = erlang:start_timer(Time, self(), poll),
    {noreply, S#state{poll_ref=NewRef, set=NewSet}};
handle_info(_, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%%%%%%%%%%%%%%
%%% PRIVATE %%%
%%%%%%%%%%%%%%%
send_events(Name, {Del, Add, Mod}) ->
    [gproc:send({p, l, Name}, make_event(Name, {deleted, D})) || D <- Del],
    [gproc:send({p, l, Name}, make_event(Name, {added, A})) || A <- Add],
    [gproc:send({p, l, Name}, make_event(Name, {changed, C})) || C <- Mod],
    ok.

make_event(Name, Event) -> {dirmon, Name, Event}.

initial_sync(scan, _Name, Dir, Ignore, Time) ->
    %% Minimal use case to always start from a fresh state.
    {revault_dirmon_poll:scan(Dir, Ignore),
     erlang:start_timer(Time, self(), poll)};
initial_sync(tracker_manual, Name, _Dir, _Ignore, _Time) ->
    %% Mostly used for tests, where we want to avoid scans interfering
    %% with file changes asynchronously and ruin determinism.
    AllFiles = revault_dirmon_tracker:files(Name),
    Set = lists:sort([{File, Hash} || {File, {_, Hash}} <- maps:to_list(AllFiles)]),
    %% Send in a fake ref, which prevents any timer from ever running
    {Set, make_ref()};
initial_sync(tracker, Name, _Dir, _Ignore, _Time) ->
    %% Normal stateful mode, where we load files and scan ASAP to avoid
    %% getting into modes where long delays mean we are unresponsive
    %% to filesystem changes long after boot.
    AllFiles = revault_dirmon_tracker:files(Name),
    Set = lists:sort([{File, Hash} || {File, {_, Hash}} <- maps:to_list(AllFiles)]),
    %% Fake a message to rescan asap on start
    Ref = make_ref(),
    self() ! {timeout, Ref, poll},
    {Set, Ref}.
