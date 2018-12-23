-module(revault_test_utils).
-include_lib("proper/include/proper.hrl").
-export([scratch_dir_name/0, setup_scratch_dir/1, teardown_scratch_dir/1]).
-export([gen_path/0]).

%%%%%%%%%%%%%%%%%%%%%%
%%% UTIL FUNCTIONS %%%
%%%%%%%%%%%%%%%%%%%%%%
scratch_dir_name() ->
    T = erlang:monotonic_time(),
    C = erlang:unique_integer([positive, monotonic]),
    Name = integer_to_list(T) ++ "_" ++ integer_to_list(C),
    filename:join(["_build", "test", "scratch", Name]).

setup_scratch_dir(Dir) ->
    filelib:ensure_dir(filename:join([Dir, ".touch"])),
    Dir.

teardown_scratch_dir(Dir) ->
    AllDirs = filelib:fold_files(
        Dir, ".*", true,
        fun(File, Acc) ->
            file:delete(File),
            [filename:dirname(File) | Acc]
        end, []),
    Dirs = lists:usort(lists:append(
        [all_paths(drop_file_prefix(Dir, D)) || D <- lists:usort(AllDirs)]
    )),
    _ = [file:del_dir(filename:join(Dir, D)) || D <- lists:reverse(Dirs)],
    file:del_dir(Dir),
    ok.

%%%%%%%%%%%%%%%%%%
%%% GENERATORS %%%
%%%%%%%%%%%%%%%%%%
gen_path() ->
    ?SUCHTHAT(
       Path,
       ?LET(Frags, gen_filename(),
            filename:join(Frags)),
       byte_size(unicode:characters_to_binary(Path)) < 256
    ).

gen_filename() ->
    non_empty(list(gen_filename_part())).

gen_filename_part() ->
    ?LET(B, non_empty(path_chars()), unicode:characters_to_list(B)).

path_chars() ->
    list(oneof([
        range($0,$9), range($a,$z), range($A, $Z),
        oneof(" &%!'\":;^"),
        range(16#1F600, 16#1F64F)
    ])).

%%%%%%%%%%%%%%%
%%% PRIVATE %%%
%%%%%%%%%%%%%%%
drop_file_prefix(Dir, Path) ->
    drop_file_prefix_(filename:split(Dir), filename:split(Path)).

drop_file_prefix_([X|As], [X|Bs]) -> drop_file_prefix_(As, Bs);
drop_file_prefix_(_, []) -> [];
drop_file_prefix_(_, Rest) -> filename:join(Rest).

all_paths(Path) ->
    all_paths(filename:split(Path), []).

all_paths([], Acc) -> Acc;
all_paths([H|T], []) -> all_paths(T, [H]);
all_paths([H|T], [P|Ps]) ->
    all_paths(T, [filename:join(P,H), P | Ps]).

