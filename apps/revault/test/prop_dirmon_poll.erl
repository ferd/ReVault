-module(prop_dirmon_poll).
-compile(export_all).
-include_lib("proper/include/proper.hrl").

prop_diff_set(doc) ->
    "Test the internal function that does diffing of subsets of "
    "files to find what changed over time.".
prop_diff_set() ->
    ?FORALL({Base, Add, Del, Change, End}, hash_gen(),
      begin
          {D, A, M} = revault_dirmon_poll:diff_set(Base, End),
          ?WHENFAIL(
             io:format("~p vs ~p~n", [{Add,Del,Change}, {D,A,M}]),
             D == Del andalso A == Add andalso M == Change
          )
      end).

%%%%%%%%%%%%%%%%%%
%%% GENERATORS %%%
%%%%%%%%%%%%%%%%%%
hash_gen() ->
    KeyGen = ?LET(Ks, non_empty(list(string())), lists:usort(Ks)),
    HashGen = ?LET(Ks, KeyGen, [{K, binary()} || K <- Ks]),
    ?LET(End, HashGen,
      ?LET(TmpAdded, list(oneof(End)),
        begin
          Added = lists:usort(TmpAdded),
          case End -- Added of
            [] ->
                {[], Added, [], [], End};
            Tmp1 ->
                ?LET(TmpChanged, list(oneof(Tmp1)),
                 begin
                    Changed = lists:usort(TmpChanged),
                    Init = [case lists:member({K,B}, Changed) of
                                true -> {K, <<1, B/binary>>};
                                false -> {K, B}
                            end || {K,B} <- Tmp1],
                    ?LET(TmpDel, HashGen,
                      begin
                        Del = [{K, B} || {K, B} <- TmpDel,
                                         false == lists:keyfind(K, 1, End)],
                        {lists:sort(Init++Del), Added, Del, Changed, End}
                      end)
                 end)
          end
       end)
    ).
