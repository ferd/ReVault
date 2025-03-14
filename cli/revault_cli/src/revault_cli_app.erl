-module(revault_cli_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    revault_curses:start_link(revault_cli_mod).

stop(_State) ->
    ok.
