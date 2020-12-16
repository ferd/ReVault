%%% @doc Shim module for ID-handling at the protocol level.
-module(id_shim).
-export([start_link/0, stop/0,
         id_ask/2, id_reply/3, inspect_id/1]).
-export([init/1, handle_call/3]).

%% Fixtures for each test iteration, setting up and tearing down
%% state.
start_link() ->
    {ok, _Client} = gen_server:start_link({local, client}, ?MODULE, [], []),
    {ok, _Server} = gen_server:start_link({local, server}, ?MODULE, [], []),
    gen_server:call(client, {set, id, undefined}),
    gen_server:call(server, {set, id, revault_id:new()}),
    {ok, many_pids}.

stop() ->
    gen_server:stop(client),
    gen_server:stop(server),
    ok.

id_ask(_From, _To) ->
    ok.

id_reply(From, To, Id) ->
    ok.

inspect_id(Name) ->
    gen_server:call(Name, {get, id}).

%%% PRIVATE STORE FUNCTIONALITY
init([]) ->
    {ok, #{}}.

handle_call({get, K}, _From, Map) ->
    {reply, maps:get(K, Map), Map};
handle_call({set, K, V}, _From, Map) ->
    {reply, ok, Map#{K => V}}.
