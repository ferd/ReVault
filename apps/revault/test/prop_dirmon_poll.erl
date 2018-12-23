-module(prop_dirmon_poll).
-compile(export_all).
-include_lib("proper/include/proper.hrl").

prop_detect(doc) ->
    "Create a set of files and make sure that the scanner can find "
    "all of them".
%% - setup directory
%% - ensure the whole list of directories and files can be found
%%   - give a hash for each file (sha256?)
%% - apply changes
%% - ensure changes are found
%%   - new files, changed files, dropped files
%% - clean up directory
prop_detect() ->
    Dir = revault_test_utils:scratch_dir_name(),
    ?SETUP(fun() ->
        revault_test_utils:setup_scratch_dir(Dir),
        fun() -> revault_test_utils:teardown_scratch_dir(Dir) end
    end,
    ?FORALL({Files, Ops}, populate_dir(Dir),
      begin
        revault_test_utils:setup_scratch_dir(Dir),
        eval(Ops),
        Found = revault_dirmon_poll:scan(Dir),
        revault_test_utils:teardown_scratch_dir(Dir),
        ?WHENFAIL(io:format("Expected: ~tp~n"
                            "Found: ~tp~n", [Files, Found]),
                  lists:usort(Files) == lists:sort(Found))
      end
    )).

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
           [{'call', filelib, ensure_dir, [P]},
              {'call', file, write_file, [P, C]}]}).
