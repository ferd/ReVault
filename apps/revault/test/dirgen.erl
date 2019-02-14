%% @doc
%% Bunch of generators that are useful to use for directory generation
-module(dirgen).
-include_lib("proper/include/proper.hrl").
-compile(export_all).

path() ->
    non_empty(list(path_chars())).

path_chars() ->
    non_empty(list(frequency([
        {1, range($0, $9)},
        {5, range($a, $z)},
        {5, range($A, $Z)},
        {1, oneof(". &%!'\":;^")},
        {1, range(16#1F600, 16#1F64F)}
    ]))).
