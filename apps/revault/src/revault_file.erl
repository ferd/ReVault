-module(revault_file).
-export([hash/1, hash_bin/1,
         make_relative/2,
         copy/2,
         tmp/0, tmp/1, extension/2,
         find_hashes/2,
         %% wrappers to file module
         delete/1, consult/1, read_file/1, ensure_dir/1, is_file/1,
         write_file/2, write_file/3, rename/2]).

-type hash() :: binary().
-export_type([hash/0]).

%% @doc takes a file and computes a hash for it as used to track changes
%% in ReVault. This hash is not guaranteed to be stable, but at this time
%% it is SHA256.
-spec hash(file:filename_all()) -> hash().
hash(Path) ->
    (mod()):hash(Path).

%% @doc takes a binary and computes a hash for it as used to track changes
%% and validate payloads in ReVault. This hash is not guaranteed to be
%% stable, but at this time it is SHA256.
-spec hash_bin(binary()) -> hash().
hash_bin(Bin) ->
    crypto:hash(sha256, Bin).

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
    (mod()):copy(From, To).

%% @doc returns the name of a file using a safe temporary path. Relies
%% on the instantiation of a cached value for a safe temporary directory
%% on the local filesystem to allow safe renames without exdev errors,
%% which my try to write and delete other temporary files.
%% Once the check is done, it does not need to be repeated.
-spec tmp() -> file:filename_all().
tmp() ->
    (mod()):tmp().

%% @doc returns the name `Path' of a file located in a temporary directory.
%% Relies on the instantiation of a cached value for a safe temporary directory
%% on the local filesystem to allow safe renames without exdev errors,
%% which my try to write and delete other temporary files.
%% Once the check is done, it does not need to be repeated.
-spec tmp(file:filename_all()) -> file:filename_all().
tmp(Path) ->
    (mod()):tmp(Path).

%% @doc appends an extensino `Ext' to a path `Path' in a safe manner
%% considering the possible types of `file:filename_all()' as a datatype.
%% A sort of counterpart to `filename:extension/1'.
-spec extension(file:filename_all(), string()) -> file:filename_all().
extension(Path, Ext) when is_list(Path) ->
    Path ++ Ext;
extension(Path, Ext) when is_binary(Path) ->
    BinExt = <<_/binary>> = unicode:characters_to_binary(Ext),
    <<Path/binary, BinExt/binary>>.

%% @doc Traverses a directory `Dir' recursively, looking at every file
%% that matches `Pred', and extracts a hash (as computed by `hash/1')
%% matching its contents.
%%
%% The list of filenames and hashes is returned in no specific order.
-spec find_hashes(Dir, Pred) -> [{file:filename(), hash()}] when
    Dir :: file:filename(),
    Pred :: fun((file:filename()) -> boolean()).
find_hashes(Dir, Pred) ->
    (mod()):find_hashes(Dir, Pred).

%%%%%%%%%%%%%%%%%%%%%
%%% FILE WRAPPERS %%%
%%%%%%%%%%%%%%%%%%%%%

%% @doc Deletes a file.
-spec delete(file:filename_all()) -> ok | {error, badarg | file:posix()}.
delete(Path) ->
    (mod()):delete(Path).

%% @doc Reads Erlang terms, separated by '.', from Filename.
-spec consult(file:filename_all()) -> {ok, [term()]} | {error, Reason}
        when Reason :: file:posix()
                     | badarg | terminated | system_limit
                     | {integer(), module(), term()}.
consult(Path) ->
    (mod()):consult(Path).

%% @doc Reads the whole file.
-spec read_file(file:filename_all()) -> {ok, binary()} | {error, badarg | file:posix()}.
read_file(Path) ->
    (mod()):read_file(Path).

%% @doc Ensures that all parent directories for the specified file or
%% directory name `Name' exist, trying to create them if necessary.
-spec ensure_dir(file:filename_all()) -> ok | {error, file:posix()}.
ensure_dir(Path) ->
    (mod()):ensure_dir(Path).

%% @doc Returns true if the path refers to a file or a directory,
%% otherwise false.
-spec is_file(file:filename_all()) -> boolean().
is_file(Path) ->
    (mod()):is_file(Path).

%% @doc Writes the content to the file mentioned.  The file is created if it
%% does not exist. If it exists, the previous contents are overwritten.
-spec write_file(file:filename_all(), iodata()) -> ok | {error, badarg | file:posix()}.
write_file(Path, Data) ->
    (mod()):write_file(Path, Data).

%% @doc Writes the content to the file mentioned.  The file is created if it
%% does not exist. If it exists, the previous contents are overwritten.
-spec write_file(file:filename_all(), iodata(), [Mode]) ->
        ok | {error, badarg | file:posix()}
    when Mode :: read | write | append | exclusive | raw | binary | sync.
write_file(Path, Data, Modes) ->
    (mod()):write_file(Path, Data, Modes).

%% @doc Tries to rename the file Source to Destination.
-spec rename(Source, Destination) -> ok | {error, badarg | file:posix()}
    when Source :: file:filename_all(),
         Destination :: file:filename_all().
rename(Source, Destination) ->
    (mod()):rename(Source, Destination).

%%%%%%%%%%%%%%%
%%% PRIVATE %%%
%%%%%%%%%%%%%%%

mod() ->
    case application:get_env(revault, backend, disk) of
        disk -> revault_file_disk;
        s3 -> revault_s3
    end.

