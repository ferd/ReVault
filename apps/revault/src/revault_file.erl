-module(revault_file).
-export([make_relative/2]).

make_relative(Dir, File) ->
    do_make_relative_path(filename:split(Dir), filename:split(File)).

do_make_relative_path([H|T1], [H|T2]) ->
    do_make_relative_path(T1, T2);
do_make_relative_path([], Target) ->
    filename:join(Target).
