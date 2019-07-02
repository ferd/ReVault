%%% @doc
%%% Server in charge of listening to events about a given directory and
%%% tracking all the changes in memory
%%% @end
-module(revault_dirmon_tracker).
-behviour(gen_server).
-define(VIA_GPROC(Name), {via, gproc, {n, l, {?MODULE, Name}}}).
-export([start_link/1, stop/1, file/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-opaque stamp() :: {at, integer()}.
-export_type([stamp/0]).

%% optimization hint: replace the queue by an ordered_set ETS table?
-record(state, {
    snapshot = #{} :: #{file:filename() =>
                        {stamp(), revault_dirmon_poll:hash()}}
}).

start_link(Name) ->
    gen_server:start_link(?VIA_GPROC(Name), ?MODULE, [Name], []).

file(Name, File) ->
    gen_server:call(?VIA_GPROC(Name), {file, File}).

stop(Name) ->
    gen_server:stop(?VIA_GPROC(Name), normal, 5000).
init([Name]) ->
    true = gproc:reg({p, l, Name}),
    {ok, #state{}}.


handle_call({file, Name}, _From, State = #state{snapshot=Map}) ->
    case Map of
        #{Name := Status} ->
            {reply, Status, State};
        _ ->
            {reply, undefined, State}
    end;
handle_call(_Call, _From, State) ->
    {noreply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({dirmon, _Name, {Transform, _} = Op}, State=#state{snapshot=Map})
        when Transform == deleted;
             Transform == added;
             Transform == changed ->
    {noreply, State#state{snapshot = apply_operation(Op, Map)}};
handle_info(_Msg, State) ->
    {noreply, State}.

stamp() ->
    {at, erlang:unique_integer([positive, monotonic])}.

apply_operation({added, {FileName, Hash}}, SetMap) ->
    SetMap#{FileName => {stamp(), Hash}};
apply_operation({deleted, {FileName, _Hash}}, SetMap) ->
    SetMap#{FileName := {stamp(), deleted}};
apply_operation({changed, {FileName, Hash}}, SetMap) ->
    SetMap#{FileName := {stamp(), Hash}}.
