-module(revault_s3_cache).
-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export([start_link/2,
         ensure_loaded/1, hash/2, hash_store/3, save/1]).

-record(state, {db_dir,
                cache_file,
                name,
                cache = #{}}).

-define(VIA_GPROC(Name), {via, gproc, {n, l, {?MODULE, Name}}}).

-ifdef(TEST).
%-define(DEBUG_OPTS, [{debug, [trace]}]).
-define(DEBUG_OPTS, []).
-else.
-define(DEBUG_OPTS, []).
-endif.

%% `Name' is expected to be `Dir' by callers.
start_link(DbDir, Name) ->
    gen_server:start_link(?VIA_GPROC(Name), ?MODULE, {DbDir, Name}, ?DEBUG_OPTS).

%% TODO decide if this call should also start the cache process if not loaded.
ensure_loaded(Name) ->
    gen_server:call(?VIA_GPROC(Name), load, timer:minutes(1)).

%% since we are mostly caching for cost ($) and not speed, it's okay to go simple
%% and serialize all reads and writes.
hash(Name, Key) ->
    gen_server:call(?VIA_GPROC(Name), {get, Key}, timer:minutes(1)).

hash_store(Name, Key, Val) ->
    gen_server:call(?VIA_GPROC(Name), {set, Key, Val}, timer:minutes(1)).

save(Name) ->
    gen_server:call(?VIA_GPROC(Name), save, timer:minutes(1)).

%%%%%%%%%%%%%%%%%
%%% CALLBACKS %%%
%%%%%%%%%%%%%%%%%
init({DbDir, Name}) ->
    CacheFile = filename:join([DbDir, Name]),
    {ok, #state{cache_file=CacheFile, name=Name}}.

handle_call(load, _From, S=#state{name=Name, cache_file=CacheFile}) ->
    Cache = case revault_s3:consult(CacheFile) of
        {ok, [{Name, Map}]} when is_map(Map) -> Map;
        {error, enoent} -> #{}
    end,
    {reply, ok, S#state{cache=Cache}};
handle_call(save, _From, S=#state{name=Name, cache_file=CacheFile, cache=Map}) ->
    Txt = io_lib:format("{~p,~p}.~n", [Name, Map]),
    ok = revault_s3:write_file(CacheFile, unicode:characters_to_binary(Txt)),
    {reply, ok, S};
handle_call({get, Key}, _From, S=#state{cache=Map}) ->
    Res = case Map of
        #{Key := Val} -> {ok, Val};
        _ -> undefined
    end,
    {reply, Res, S};
handle_call({set, Key, Val}, _From, S=#state{cache=Map}) ->
    NewMap = Map#{Key => Val},
    {reply, ok, S#state{cache=NewMap}};
handle_call(_, _From, S=#state{}) ->
    {noreply, S}.

handle_cast(_, S=#state{}) ->
    {noreply, S}.

handle_info(_, S=#state{}) ->
    {noreply, S}.

