-module(revault_dirmon_event).
-export([start_link/2, force_scan/2, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {name :: term(),
                directory :: file:filename(),
                poll_delay :: timeout(),
                poll_ref :: reference(),
                set :: revault_dirmon_poll:set()}).

%%%%%%%%%%%%%%%%%%
%%% PUBLIC API %%%
%%%%%%%%%%%%%%%%%%
start_link(Name, Opts) ->
    gen_server:start_link({via, gproc, {n, l, Name}}, ?MODULE,
                          Opts#{name => Name}, []).

force_scan(Name, Wait) ->
    gen_server:call({via, gproc, {n, l, Name}}, force_scan, Wait).

stop(Name) ->
    gen_server:stop({via, gproc, {n, l, Name}}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% GEN_SERVER CALLBACKS %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%
init(#{directory := Dir, poll_interval := Time, name := Name}) ->
    Ref = erlang:start_timer(Time, self(), poll),
    {ok, #state{name = Name,
                directory = Dir,
                poll_delay = Time,
                poll_ref = Ref,
                set = revault_dirmon_poll:scan(Dir)}}.

handle_call(force_scan, _From, S=#state{name=Name, directory=Dir, set=Set}) ->
    {Updates, NewSet} = revault_dirmon_poll:rescan(Dir, Set),
    send_events(Name, Updates),
    {reply, ok, S#state{set = NewSet}};
handle_call(_, _From, State) ->
    {noreply, State}.

handle_cast(_, State) ->
    {noreply, State}.

handle_info({timeout, TRef, poll}, S=#state{name=Name, directory=Dir, set=Set,
                                            poll_delay=Time, poll_ref=TRef}) ->
    {Updates, NewSet} = revault_dirmon_poll:rescan(Dir, Set),
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
