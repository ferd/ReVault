-module(revault_signal_handler).
-behaviour(gen_event).
-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2]).

init(Pid) ->
    {ok, Pid}.

handle_event(sigwinch, Pid) ->
    Pid ! {signal, sigwinch},
    {ok, Pid};
handle_event(_, Pid) ->
    {ok, Pid}.

handle_call(_, Pid) ->
    {ok, ok, Pid}.

handle_info(_, Pid) ->
    {ok, Pid}.

terminate(_, _) ->
    ok.
