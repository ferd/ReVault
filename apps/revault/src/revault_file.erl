-module(revault_file).
-export([make_relative/2, copy/2, extension/2]).

%% @doc makes path `File' relative to `Dir', such that if you pass in
%% `/a/b/c/d.txt' and the `Dir' path `/a/b', you get `c/d.txt'.
-spec make_relative(Dir, File) -> Rel
    when Dir :: file:filename_all(),
         File :: file:filename_all(),
         Rel :: file:filename_all().
make_relative(Dir, File) ->
    do_make_relative_path(filename:split(Dir), filename:split(File)).

do_make_relative_path([H|T1], [H|T2]) ->
    do_make_relative_path(T1, T2);
do_make_relative_path([], Target) ->
    filename:join(Target).

%% @doc copies a file from a path `From' to location `To'. Uses a
%% temporary file that then gets renamed to the final location in order
%% to avoid issues in cases of crashes. If the `/tmp' directory is on
%% a different filesystem, this behavior is going to fail and different
%% `TMPDIR' must be configured.
%% @end
%% TODO: write a test on boot for this behavior?
-spec copy(From, To) -> ok | {error, file:posix()}
    when From :: file:filename_all(),
         To :: file:filename_all().
copy(From, To) ->
    RandVal = float_to_list(rand:uniform()),
    TmpFile = filename:join([system_tmpdir(), RandVal]),
    ok = filelib:ensure_dir(TmpFile),
    ok = filelib:ensure_dir(To),
    {ok, _} = file:copy(From, TmpFile),
    file:rename(TmpFile, To).

%% @doc appends an extensino `Ext' to a path `Path' in a safe manner
%% considering the possible types of `file:filename_all()' as a datatype.
%% A sort of counterpart to `filename:extension/1'.
-spec extension(file:filename_all(), string()) -> file:filename_all().
extension(Path, Ext) when is_list(Path) ->
    Path ++ Ext;
extension(Path, Ext) when is_binary(Path) ->
    BinExt = <<_/binary>> = unicode:characters_to_binary(Ext),
    <<Path/binary, BinExt/binary>>.

%%%%%%%%%%%%%%%
%%% PRIVATE %%%
%%%%%%%%%%%%%%%
system_tmpdir() ->
    case erlang:system_info(system_architecture) of
        "win32" ->
            filename:join([filename:basedir(user_cache, "revault"), "tmp"]);
        _SysArch ->
            os:getenv("TMPDIR", "/tmp")
    end.
