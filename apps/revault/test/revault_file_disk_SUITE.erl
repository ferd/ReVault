-module(revault_file_disk_SUITE).
-compile(export_all).
-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").

all() ->
    [read_range, multipart].

read_range() ->
    [{doc, "general checks on reading subsets of files"}].
read_range(Config) ->
    WidthBytes = 100,
    WidthBits = 8*WidthBytes,
    Bin = <<0:WidthBits, 1:WidthBits, 2:WidthBits, 3:WidthBits, 4:WidthBits,
            5:WidthBits, 6:WidthBits, 7:WidthBits, 8:WidthBits, 9:WidthBits>>,
    File = filename:join([?config(priv_dir, Config), "read_range.scratch"]),
    file:write_file(File, Bin),
    ?assertMatch({ok, Bin}, revault_file_disk:read_range(File, 0, WidthBytes*10)),
    ?assertMatch({error, _}, revault_file_disk:read_range(File, 0, WidthBytes*10+1000)),
    ?assertMatch({error, _}, revault_file_disk:read_range(File, WidthBytes*1000, 1)),
    ?assertMatch({ok, <<5:100/unit:8, _:400/binary>>},
                 revault_file_disk:read_range(File, WidthBytes*5, WidthBytes*5)),
    ?assertMatch({ok, <<5:100/unit:8>>},
                 revault_file_disk:read_range(File, WidthBytes*5, WidthBytes)),
    ?assertMatch({ok, <<5:100/unit:8, 0>>},
                 revault_file_disk:read_range(File, WidthBytes*5, WidthBytes+1)),
    ok.

multipart() ->
    [{doc, "Basic tests on multipart API use"}].
multipart(Config) ->
    WidthBytes = 100,
    WidthBits = 8*WidthBytes,
    Parts = 11,
    Bin = <<0:WidthBits, 1:WidthBits, 2:WidthBits, 3:WidthBits, 4:WidthBits,
            5:WidthBits, 6:WidthBits, 7:WidthBits, 8:WidthBits, 9:WidthBits, 10>>,
    Hash = revault_file_disk:hash_bin(Bin),
    File = filename:join([?config(priv_dir, Config), "multipart.scratch"]),
    {_, State} = lists:foldl(
        fun(Part, {N,S}) ->
            {ok, NewS} = revault_file_disk:multipart_update(S, File, N, Parts, Hash, Part),
            {N+1, NewS}
        end,
        {1, revault_file_disk:multipart_init(File, Parts, Hash)},
        [<<N:WidthBits>> || N <- lists:seq(0,Parts-2)]++[<<10>>]
    ),
    ok = revault_file_disk:multipart_final(State, File, Parts, Hash),
    ?assertEqual({ok, Bin}, file:read_file(File)),
    ok.
