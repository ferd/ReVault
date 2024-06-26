-module(revault_file_disk_SUITE).
-compile(export_all).
-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").

all() ->
    [read_range, multipart, multipart_hash,
     hash_large_file].

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

multiparti_hash() ->
    [{doc, "Multipart API validates the hash when finalizing"}].
multipart_hash(Config) ->
    WidthBytes = 100,
    WidthBits = 8*WidthBytes,
    Parts = 11,
    Bin = <<0:WidthBits, 1:WidthBits, 2:WidthBits, 3:WidthBits, 4:WidthBits,
            5:WidthBits, 6:WidthBits, 7:WidthBits, 8:WidthBits, 9:WidthBits, 10>>,
    Hash = revault_file_disk:hash_bin(<<1, Bin/binary>>),
    File = filename:join([?config(priv_dir, Config), "multipart.scratch"]),
    {_, State} = lists:foldl(
        fun(Part, {N,S}) ->
            {ok, NewS} = revault_file_disk:multipart_update(S, File, N, Parts, Hash, Part),
            {N+1, NewS}
        end,
        {1, revault_file_disk:multipart_init(File, Parts, Hash)},
        [<<N:WidthBits>> || N <- lists:seq(0,Parts-2)]++[<<10>>]
    ),
    ?assertError(invalid_hash,
                 revault_file_disk:multipart_final(State, File, Parts, Hash)),
    ok.

hash_large_file() ->
    [{doc, "hashing large files can be done in an iterative manner"}].
hash_large_file(Config) ->
    WidthBytes = 100,
    WidthBits = 8*WidthBytes,
    Parts = 11,
    Bin = <<0:WidthBits, 1:WidthBits, 2:WidthBits, 3:WidthBits, 4:WidthBits,
            5:WidthBits, 6:WidthBits, 7:WidthBits, 8:WidthBits, 9:WidthBits, 10>>,
    File = filename:join([?config(priv_dir, Config), "multipart.scratch"]),
    ok = file:write_file(File, Bin),
    Hash = revault_file_disk:hash_bin(<<Bin/binary>>),
    %% do the streaming hash read
    Multipart = application:get_env(revault, multipart_size),
    application:set_env(revault, multipart_size, WidthBytes),
    HashDisk = revault_file_disk:hash(File),
    case Multipart of
        undefined -> application:unset_env(revault, multipart_size);
        {ok, Multipart} -> application:set_env(revault, multipart_size, Multipart)
    end,
    ?assertEqual(HashDisk, Hash),
    ok.
