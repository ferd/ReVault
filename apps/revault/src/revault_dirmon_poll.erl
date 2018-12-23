-module(revault_dirmon_poll).
-export([scan/1]).

scan(Dir) ->
    filelib:fold_files(
      Dir, ".*", true,
      fun(File, Acc) ->
         {ok, Bin} = file:read_file(File),
         Hash = crypto:hash(sha256, Bin),
         [{File, Hash} | Acc]
      end, []
    ).
