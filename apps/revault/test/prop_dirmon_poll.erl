-module(prop_dirmon_poll).
-compile(export_all).
-include_lib("proper/include/proper.hrl").

prop_first_scan(doc) ->
    "Create a set of files and make sure that the scanner can find "
    "all of them".
%% - setup directory
%% - ensure the whole list of directories and files can be found
%%   - give a hash for each file (sha256?)
%% - clean up directory
prop_first_scan() ->
    Dir = revault_test_utils:scratch_dir_name(),
    %% Use ?SETUP(...) to ensure the directory is cleaned up
    %% even on failing runs
    ?SETUP(fun() ->
        revault_test_utils:setup_scratch_dir(Dir),
        fun() -> revault_test_utils:teardown_scratch_dir(Dir) end
    end,
    ?FORALL({Files, Ops}, populate_dir(Dir),
      begin
        revault_test_utils:setup_scratch_dir(Dir),
        run_ops(Ops),
        Found = revault_dirmon_poll:scan(Dir),
        revault_test_utils:teardown_scratch_dir(Dir),
        ?WHENFAIL(io:format("Expected: ~tp~n"
                            "Found: ~tp~n", [Files, Found]),
                  lists:usort(Files) == lists:sort(Found))
      end
    )).

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
populate_dir(Base) ->
    ?LET(Pairs, list(make_file(Base)),
         begin
             %% Drop a file that's also a path of another one
             ValidPairs = [P || P = {{Path,_}, _} <- Pairs,
                                not is_dir(filename:split(Path), Pairs)],
             lists:unzip(ValidPairs)
         end).


is_dir(_Path, []) -> false;
is_dir(Path, [{{Candidate,_},_}|Rest]) ->
    Dir = lists:droplast(filename:split(Candidate)),
    lists:prefix(Path, Dir) orelse is_dir(Path, Rest).

make_file(Base) ->
    Name = revault_test_utils:gen_path(),
    Content = binary(),
    Path = ?LET(N, Name, filename:join(Base, N)),
    ?LET({P,C}, {Path, Content},
         {{P, crypto:hash(sha256, C)},
           [{call, filelib, ensure_dir, [P]},
            {call, file, write_file, [P, C, [sync]]}]}).

run_ops(Ops) ->
    Res = eval(Ops),
    Res.

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
