%%% @doc
%%% Basic polling mechanism used to scan directories and find
%%% all the file hashes and fetch the changes they might contain
%%% @end
-module(revault_dirmon_poll).
-export([scan/1, rescan/2]).

-type hash() :: binary().
-type set() :: [{file:filename(), hash()}].
-export_type([set/0, hash/0]).

-ifdef(TEST).
-export([diff_set/2]).
-endif.

%%%%%%%%%%%%%%
%%% PUBLIC %%%
%%%%%%%%%%%%%%

%% @doc Initial scan of a directory. Returns all the found filenames
%% along with their SHA256 value. The returned value is sorted.
-spec scan(file:filename()) -> set().
scan(Dir) ->
    lists:sort(filelib:fold_files(
      Dir, ".*", true,
      fun(File, Acc) ->
         {ok, Bin} = file:read_file(File),
         Hash = crypto:hash(sha256, Bin),
         [{File, Hash} | Acc]
      end, []
    )).

%% @doc Repeat the scan of a directory from a previously known set.
%% Returns a 2-tuple. The first element is a triple containing
%% `{DeletedFiles, AddedFiles, ModifiedFiles}', and the second element
%% is the new set of all found filenames along with their SHA256 value.
%% Assumes the input set is sorted, and similarly returns sorted lists.
-spec rescan(file:filename(), set()) ->
    {{Deleted, Added, Modified}, HashSet} when
      Deleted :: HashSet,
      Added :: HashSet,
      Modified :: HashSet,
      HashSet :: set().
rescan(Dir, OldSet) ->
    NewSet = scan(Dir),
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
