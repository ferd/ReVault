-module(cfg_SUITE).
-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all, nowarn_export_all]).

all() -> [literal, from_file, from_default_file].

init_per_testcase(from_default_file, Config) ->
    CfgFile = filename:join(?config(data_dir, Config), "sample.toml"),
    meck:new(maestro_cfg, [passthrough]),
    meck:expect(maestro_cfg, config_path, fun() -> CfgFile end),
    Config;
init_per_testcase(_, Config) ->
    Config.

end_per_testcase(_, Config) ->
    Config.

literal(Config) ->
    CfgFile = filename:join(?config(data_dir, Config), "sample.toml"),
    {ok, Bin} = file:read_file(CfgFile),
    {ok, Cfg} = maestro_cfg:parse(Bin),
    ?assertMatch(
       #{<<"db">> := #{
             <<"path">> := <<"/Users/ferd/.config/ReVault/db/">>
         },
         <<"dirs">> := #{
            <<"music">> := #{
                <<"interval">> := 60,
                <<"path">> := <<"~/Music">>,
                <<"ignore">> := []
            },
            <<"images">> := #{
                <<"interval">> := 60,
                <<"path">> := <<"/Users/ferd/images/">>,
                <<"ignore">> := []
            }
         },
         <<"peers">> := #{
            <<"vps">> := #{
                <<"sync">> := [<<"images">>],
                <<"url">> := <<"leetzone.ca:8022">>,
                <<"auth">> := #{
                    <<"type">> := <<"ssh">>,
                    <<"cert">> := <<_/binary>>
                }
            },
            <<"local">> := #{
                <<"sync">> := [<<"images">>, <<"music">>],
                <<"url">> := <<"localhost:8888">>,
                <<"auth">> := #{
                    <<"type">> := <<"none">>
                }
            }
         },
         <<"server">> := #{
            <<"auth">> := #{
                <<"none">> := #{
                    <<"status">> := enabled,
                    <<"port">> := 9999,
                    <<"sync">> := [<<"images">>, <<"music">>],
                    <<"mode">> := read_write
                },
                <<"ssh">> := #{
                    <<"status">> := disabled,
                    <<"port">> := 8022,
                    <<"authorized_keys">> := #{
                        <<"vps">> := #{
                            <<"public_key">> := <<_/binary>>,
                            <<"sync">> := [<<"images">>, <<"music">>],
                            <<"mode">> := read_write
                        },
                        <<"friendo">> := #{
                            <<"public_key">> := <<_/binary>>,
                            <<"sync">> := [<<"music">>],
                            <<"mode">> := read
                        }
                    }
                }
            }
         }
       },
       Cfg
    ),
    ok.

from_file(Config) ->
    CfgFile = filename:join(?config(data_dir, Config), "sample.toml"),
    {ok, Cfg} = maestro_cfg:parse_file(CfgFile),
    ?assertMatch(
       #{<<"db">> := _,
         <<"dirs">> := _,
         <<"peers">> := _,
         <<"server">> := _
       },
       Cfg
    ),
    ok.

from_default_file(_Config) ->
    {ok, Cfg} = maestro_cfg:parse_file(),
    ?assertMatch(
       #{<<"db">> := _,
         <<"dirs">> := _,
         <<"peers">> := _,
         <<"server">> := _
       },
       Cfg
    ),
    ok.
