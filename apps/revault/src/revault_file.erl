-module(revault_file).
-export([make_relative/2, copy/2, tmp/0, tmp/1, extension/2]).

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
%% a different filesystem, this behavior is going to fallback to the
%% local user cache.
%%
%% If neither supports a safe rename operaiton, you may have to define
%% a different OS env `REVAULT_TMPDIR' value to work safely.
%% @end
-spec copy(From, To) -> ok | {error, file:posix()}
    when From :: file:filename_all(),
         To :: file:filename_all().
copy(From, To) ->
    TmpFile = tmp(),
    ok = filelib:ensure_dir(TmpFile),
    ok = filelib:ensure_dir(To),
    {ok, _} = file:copy(From, TmpFile),
    file:rename(TmpFile, To).

%% @doc returns the name of a file using a safe temporary path. Relies
%% on the instantiation of a cached value for a safe temporary directory
%% on the local filesystem to allow safe renames without exdev errors,
%% which my try to write and delete other temporary files.
%% Once the check is done, it does not need to be repeated.
-spec tmp() -> file:filename_all().
tmp() ->
    filename:join([system_tmpdir(), randname()]).

%% @doc returns the name `Path' of a file located in a temporary directory.
%% Relies on the instantiation of a cached value for a safe temporary directory
%% on the local filesystem to allow safe renames without exdev errors,
%% which my try to write and delete other temporary files.
%% Once the check is done, it does not need to be repeated.
-spec tmp(file:filename_all()) -> file:filename_all().
tmp(Path) ->
    filename:join([system_tmpdir(), Path]).

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
    case application:get_env(revault, system_tmpdir) of
        {ok, Path} ->
            Path;
        undefined ->
            case os:getenv("REVAULT_TMPDIR") of
                false ->
                    application:set_env(revault, system_tmpdir, detect_tmpdir());
                Path ->
                    application:set_env(revault, system_tmpdir, Path)
            end
    end.

detect_tmpdir() ->
    Local = filename:join([filename:basedir(user_cache, "revault"), "tmp"]),
    Posix = os:getenv("TMPDIR", "/tmp"),
    RandFile = randname(),
    PosixFile = filename:join([Posix, RandFile]),
    LocalFile = filename:join([Local, RandFile]),
    %% In some cases, this detection always fails because neither of these
    %% two filesystem paths are actually on the same filesystem as what the
    %% user will provide (eg. GithubActions containers). Falling back
    %% to `REVAULT_TMPDIR' will be required.
    case file:write_file(PosixFile, <<0>>) of
        ok ->
            filelib:ensure_dir(LocalFile),
            case file:rename(PosixFile, LocalFile) of
                {error, exdev} ->
                    file:delete(PosixFile),
                    Local;
                ok ->
                    file:delete(LocalFile),
                    Posix
            end;
        _Res ->
            Local
    end.

randname() ->
    float_to_list(rand:uniform()).
