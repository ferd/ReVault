%%% @doc
%%% Basic polling mechanism used to scan directories and find
%%% all the file hashes and fetch the changes they might contain
%%% @end
-module(revault_dirmon_poll).
-export([scan/2, rescan/3]).
-export([processable/2]).

-type set() :: [{file:filename(), revault_file:hash()}].
-type ignore() :: [binary()].
-export_type([set/0, ignore/0]).

-ifdef(TEST).
-export([diff_set/2]).
-endif.

%%%%%%%%%%%%%%
%%% PUBLIC %%%
%%%%%%%%%%%%%%

%% @doc Initial scan of a directory. Returns all the found filenames
%% along with their SHA256 value. The returned value is sorted.
-spec scan(file:filename(), ignore()) -> set().
scan(Dir, Ignore) ->
    lists:sort(revault_file:find_hashes(
        Dir,
        fun(File) -> processable(File, Ignore) end
    )).

%% @doc Repeat the scan of a directory from a previously known set.
%% Returns a 2-tuple. The first element is a triple containing
%% `{DeletedFiles, AddedFiles, ModifiedFiles}', and the second element
%% is the new set of all found filenames along with their SHA256 value.
%% Assumes the input set is sorted, and similarly returns sorted lists.
-spec rescan(file:filename(), ignore(), set()) ->
    {{Deleted, Added, Modified}, HashSet} when
      Deleted :: HashSet,
      Added :: HashSet,
      Modified :: HashSet,
      HashSet :: set().
rescan(Dir, Ignore, OldSet) ->
    NewSet = scan(Dir, Ignore),
    {diff_set(OldSet, NewSet), NewSet}.

%%%%%%%%%%%%%%%
%%% PRIVATE %%%
%%%%%%%%%%%%%%%
diff_set(Old, New) ->
    diff_set(Old, New, {[], [], []}).

diff_set([], New, {Deleted, Added, Modified}) ->
    {lists:reverse(Deleted),
     lists:reverse(Added, New),
     lists:reverse(Modified)};
diff_set(Old, [], {Deleted, Added, Modified}) ->
    {lists:reverse(Deleted, Old),
     lists:reverse(Added),
     lists:reverse(Modified)};
diff_set([X|Old], [X|New], Acc) ->
    diff_set(Old, New, Acc);
diff_set([{F, _}|Old], [{F, _}=Changed|New], {Deleted, Added, Modified}) ->
    diff_set(Old, New, {Deleted, Added, [Changed|Modified]});
diff_set([O|Old], [N|New], {Deleted, Added, Modified}) ->
    if O < N -> diff_set(Old, [N|New], {[O|Deleted], Added, Modified})
     ; O > N -> diff_set([O|Old], New, {Deleted, [N|Added], Modified})
    end.

%% @doc Takes a filename and regular expressions defining files to ignore
%% and returns whether the file is valid to process (if it matches none
%% of the regexes)
-spec processable(file:filename_all(), [string()]) -> boolean().
processable(FileName, Ignore) ->
    lists:all(fun(Regexp) -> re:run(FileName, Regexp) =:= nomatch end, Ignore).

