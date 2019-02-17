%% @doc
%% Bunch of generators that are useful to use for directory generation
-module(dirgen).
-include_lib("proper/include/proper.hrl").
-compile(export_all).

%% @doc wrapper for file operations as used by dirmodel
%% ensures that directories are all in place for simplicity
write_file(Path, Contents, Opts) ->
    filelib:ensure_dir(Path),
    file:write_file(Path, Contents, Opts).

%% @doc Equivalent to {@link write_file/3}. Named differently
%% to help with predictable models.
change_file(Path, Contents, Opts) ->
    write_file(Path, Contents, Opts).

%% @doc Equivalent to {@link write_file/3}. Named differently
%% to help with predictable models.
path_conflict_file(Path, Contents, Opts) ->
    write_file(Path, Contents, Opts).

%% @doc Equivalent to {@link write_file/3}. Named differently
%% to help with predictable models.
write_long_path(Path, Contents, Opts) ->
    write_file(Path, Contents, Opts).

%% @doc wrapper for file operations as used by dirmodel
delete_file(Path) ->
    file:delete(Path).


path() ->
    non_empty(list(path_chars())).

path_chars() ->
    ?SUCHTHAT(Chars,
              non_empty(list(frequency([
                {1, range($0, $9)},
                {5, range($a, $z)},
                {5, range($A, $Z)},
                {1, oneof(". &%!'\":;^")},
                {1, range(16#1F600, 16#1F64F)}
              ]))),
              %% Prevent ./ or ../ since they're relative
              Chars =/= "." andalso Chars =/= "..").
