# Usage

All information in this document is subject to change. ReVault is largely a toy project. Decisions and about interfaces and some specific functionality can be modified based on whims of its users, who currently are its maintainers, who are currently only one person (@ferd).

If you do have any interest in using this software or have feedback on it, drop a line to the maintainers either via GitHub issues at https://github.com/ferd/ReVault, or at any of the contact endpoints in the footer of https://ferd.ca (the maintainer's home page).

## Installing

No prebuilt artifacts are currently provided. You must [build and compile from source](#Building) to run and install ReVault.

If you were to want prebuilt artifacts, contact the maintainers about it so this could eventually get set up. Otherwise there is no incentive to the current maintainer team (of one) to actually provide this.

### Requirements

ReVault is tested on both Linux (AlmaLinux, Raspberry Pi OS) and macOS (M1 and M2 processors on Sonoma or later). Also it runs on whatever the GitHub runners are running as a Docker environment.

It expects a case-sensitive file system; While a case-insensitive file system might work, there's a much higher chance that synchronization costs over the network and conflict detection will be way too eager and it isn't a recommended environment.

It is currently untested on Windows (because the maintainer's Windows computer is an old piece of garbage that can't boot well anymore), and it is unknown how it will behave with Windows's shorter file path limitations.

Additionally, most key tests for the software are run using a file system that is Unicode-aware. You may need to configure variables for your terminal to support it, such as:

```
LANG: C.UTF-8
LC_ALL: C.UTF-8
LC_CTYPE: C.UTF-8
```

Finally, you are going to need OpenSSL >= 1.1.1 or LibreSSL >= 3.1.0 installed on your system and invokable from the command line if you want the software to generate its own keys for you.

## Building

This software is built using Erlang, because that's a cool language and this isn't up for debate. This unfortunately means that you do need to have Erlang and its toolchain installed and available to build ReVault at this point in time.

### Installing Erlang and Rebar3

Instructions are provided on [Adopting Erlang](https://adoptingerlang.org/docs/development/setup/).

Use the newest Erlang versions available (OTP-27 at the time of this writing), or look at the [CI script to find the oldest version supported](https://github.com/ferd/ReVault/blob/main/.github/workflows/erlang-ci.yml#L30-L31).

You will want to make sure the network on the loopback interface can let you talk to Erlang, as the management scripts will require it to work. You can test this once Erlang and Rebar3 are installed by running the following commands on multiple terminals:

```
# in terminal 1
$ erl -name a@127.0.0.1
Erlang/OTP 26 [erts-14.1.1] [source] [64-bit] [smp:4:4] [ds:4:4:10] [async-threads:1] [jit]

Eshell V14.1.1 (press Ctrl+G to abort, type help(). for help)
(a@127.0.0.1)1>

# in terminal 2
$ erl -name b@127.0.0.1 -remsh a@127.0.0.1
Erlang/OTP 26 [erts-14.1.1] [source] [64-bit] [smp:4:4] [ds:4:4:10] [async-threads:1] [jit]

Eshell V14.1.1 (press Ctrl+G to abort, type help(). for help)
(a@127.0.0.1)1>
```
This shows creating an Erlang node named `a@127.0.0.1`, and then creating a second one called `b@127.0.0.1` which then creates a remote shell (`-remsh`) onto `a@127.0.0.1`, which is the node in the input prompt of both terminals.

If this all works, you should be good to go. If it doesn't work, you'll need to look at things such as your firewall rules and other network configuration to make sure you can indeed connect over the loopback interface. If you see something about `epmd`, then that's a little tool Erlang requires and that error may happen because your installation is incomplete. This is likely the case if you installed from packages and disregarded the instructions on [Adopting Erlang](https://adoptingerlang.org/docs/development/setup/).

### Releases and Tools

You should also have installed `rebar3` in the previous step. With it installed, check out ReVault and build it:

```
$ git clone git@github.com:ferd/ReVault.git
...
$ cd ReVault
$ rebar3 as prod release, escriptize
...
$ ls _build/prod/rel/revault/bin/revault # main executable
_build/prod/rel/revault/bin/revault
$ ls _build/prod/bin/revault_cli         # command line tools to interact with them
_build/prod/bin/revault_cli
```

If this is built, you should be good to go. However, ReVault does nothing without adequate configuration and so we'll cover the required concepts and how to bootstrap the first host next.

## Concepts

### Directories

ReVault works by synchronizing directories of a file system. I keep hearing younger generations no longer are familiar with file systems which means I've taken so long to build my project it became obsolete before shipping, but I'm going to assume the reader knows what they are if they're reading damn Erlang toy project docs.

The directories to synchronize are specified in a config file. Each directory is specified with an alias (`books`) and a path (`/home/ferd/docs/books`). Any directory within that path can be recursively synchronized, and ReVault will ignore anything on the same level or above in the hierarchy.

The directory's alias will be used everywhere: you can synchronize between two hosts so long as they use the same alias, and you will be able to configure access and patterns using the aliases.

Generally, when "directories" are mentioned in terms of synchronization or configuration, the intended meaning is this higher-level concept of "top-level definition of a directory and all its contents."

### Nodes

Node is a really overloaded term that can mean many things, so we're just piling more on top.

We'll make a distinction between a few words. A _host_ can refer to any machine or computer that runs code, contains files, and so on. A _node_ is specifically an instance of the Erlang virtual machine. Each virtual machine instance is given a name of the form `name@hostname`.

There can therefore be multiple ReVault nodes running on a single host. We can say that nodes talk to each other, and the implication here is that one node uses its own host's network stack to connect to another host that runs another node and communicate with it.

We will also use the terms _local_ and _remote_ as qualifiers for nodes: “local” just means whichever node's context and perspective we are adopting right now, and “remote” is the peer with whom the local node is communicating.

### Clients and Servers

While _local_ and _remote_ are useful terms to denote peer-to-peer communications in a way that neither peer holds some authority over the other one, we will still need the concepts of _client_ and _server_ as well.

Generally, a _server_ is a host that idly awaits for connections and contains resources other hosts want to interact with. The _client_ is whatever host connects to the server to interact with it. Traditionally, the client therefore makes requests and the server sends responses.

In ReVault, the concepts are similar, but there are a few key critical differences.

Each directory tracked by ReVault is internally given a few identifiers:
- An [interval tree clock id](https://ferd.ca/interval-tree-clocks.html). This is a fancy data structure that can be used to create counters—one per file tracked—that lets us know which hosts have seen which files, and if modifications have logically be seen by which peers, and whether any could be conflicts.
- A UUID that uniquely identifies directories across peers, such that if two nodes that talk to each other have a directory with the same alias, but which come from two distinct histories (one is the Peterson Family photos and the other one is lots of cool memes) they don't try to synchronize and merge together (into a weird Peterson Family meme directory)

Basically, any directory tracked needs to initially be tracked by a single node. That node will create the initial UUID and set the Interval Tree Clock (ITC) to zero.

A node that boots for the first time and sees it is asked to track a directory on which it has no metadata will create the ITC and UUID only if it is configured as a server.

A node that is configured exclusively as a client will see the lack of metadata and go "Oh, I have no authority here" and will sit idle, waiting to be told which server to talk to.

When that happens, the client node with no state will connect to the server with the state, and the client will ask for it to segment its ITC space to let it also modify the clock on its own. The server will do that, hand the ITC and UUID to the client, and end the transaction.

Now that the client node has the state, it can _also_ be its own server to other peers.

Do note that in some cases, the choice of being a client or server isn't purely about information or who asks for it. For example, if you're running a node on your own laptop and another one on a hosted computer in the cloud, there's a real possibility that your Internet Service Provider or your home network's router only lets your laptop be the client; nobody from the outside world can initiate a connection from the Internet to the laptop. In such a case (and if you don't want to set up a VPN or open a port range), the network's topology forces the laptop to run a client and the host-based peer to be the server.

(ReVault has ways of letting you initiate a cloud-based host from a local one by doing part of the ID replication with a command-line tool and then letting you place that on the remote host so it boots with the state as if it had talked as a client.)

### Certificate-Based Authentication

We want encryption and protection from random weirdos accessing our data and modifying it. Rather than using users or passwords and then using encryption to communicate, ReVault directly leverages the certificates used by the TLS protocol to identify nodes.

You can have multiple sets of [private and public keys](https://www.ssl.com/article/private-and-public-keys/amp/) per node. When configuring nodes, you must specify which pairs of keys will be used by a local node, and which public key is expected out of each remote node.

Put another way, ReVault does not use [Certificate Authorities](https://en.wikipedia.org/wiki/Certificate_authority); all certificates are self-signed and pinned. This has the obvious downside that you can't automatically trust or distrust peers wholesale, each one must be managed individually.

It, however, has the advantage of being conceptually simple: just give each node its key pair, distribute the public keys to the peers you want to talk to and get theirs, write that in a config file, and that's it.

## Bootstrapping a Node

We can get practical. I'm going to assume we start from nothing.

Rather than picking an existing directory, I tend to start from a brand new one where I'll move files I want to sync elsewhere. That's not because it's a best practice, it's because while I use toy projects that mess with files I care enough to synchronize, I might as well let the software do so with copies rather than my "original" ones.

### Config File

Everything starts with a [toml](https://toml.io/en/) config file, located in your system's cache path. If you're not sure what it is, you can call the following line of code from whichever directory you had ReVault's source code checked out to:

```
$ rebar3 shell --start-clean --eval 'io:format("~ts~n", [maestro_cfg:config_path()]), halt(0).' | tail -n1
/home/ferd/.config/ReVault/config.toml
```

This path can be changed and overridden by using the `REVAULT_CONFIG` environment variable:

```
$ REVAULT_CONFIG="/tmp/test.config" \
> rebar3 shell --start-clean --eval 'io:format("~ts~n", [maestro_cfg:config_path()]), halt(0).' | tail -n1
/tmp/test.config
```

The configuration file itself should look like this—just replace the paths with your own:

```toml
## The [db] entry specifies where ReVault will be allowed to store its metadata file.
## You're not expected to modify these, the software handles it all.
[db]
  path = "/home/ferd/revault-docs/revault/db/"

## Specify the directories we want to track and synchronize
[dirs]
  ## the music directory has its own sub-configuration
  [dirs.music]
  interval = 3600 # automatically scan for modifications every 3600 seconds (1 hour)
  path = "/home/ferd/revault-docs/music/" # where the tracked files will be

## How to start a server that a client peers to...
[server]
    ## Only accept TLS for authentication. Other protocols such as TCP are
    ## supported, but mostly useful for debugging and tests. Always stick to TLS.
    [server.auth.tls]
    port = 8022 # use any port you want; the peer will need to specify it
    # These keys don't exist yet, we'll create them soon
    certfile = "/home/ferd/.config/RevAult/certs/alpha.crt"
    keyfile = "/home/ferd/.config/ReVault/certs/alpha.key"

[server.auth.tls.authorized]
    ## no one can access us yet
```

We just need these two keys to exist for the server to be able to eventually accept traffic.

### Creating the keys

when we compiled the project, we also built a command-line tool that lets us manage and interact with ReVault instances:

```
$ ./_build/prod/bin/revault_cli --help
usage: revault-cli <command>

Subcommands:
  generate-keys
  list
  remote-seed
  scan
  seed
  status
  sync

$ ./_build/prod/bin/revault_cli generate-keys --help
usage: revault-cli generate-keys [-name] [-path]

Optional arguments:
  -name Name of the key files generated (string, revault)
  -path Directory where the key files will be placed (string, ./)
```

Let's create those we had in the config file:

```
$ ./_build/prod/bin/revault_cli generate-keys -path "/home/ferd/.config/ReVault/certs/" -name alpha
... < bunch of text > ...
-----

$ ls /home/ferd/.config/ReVault/certs/
alpha.crt  alpha.key
```

Let's add some files to the music directory we'll want to track and make sure they're there, and make sure all the other directories exist:

```
$ ls ~/revault-docs/music/
cool.mp3
$ mkdir -p /tmp/revault-docs/revault/db/
...
```

Now we can boot the node:

```
$ ./_build/prod/rel/revault/bin/revault console
...
(revault@ferd.local)1>
```
This shows the node is running, and the host name generated is `revault@ferd.local`. This is the name of the node on my current host on my own network.

We can validate the configuration seen by the host in its internal format:

```
./_build/prod/bin/revault_cli list
Config parsed from /home/ferd/.config/ReVault/config.toml:
#{<<"backend">> => #{<<"mode">> => <<"disk">>},
  <<"db">> => #{<<"path">> => <<"/home/ferd/revault-docs/revault/db/">>},
  <<"dirs">> =>
      #{<<"music">> =>
            #{<<"ignore">> => [<<"\\.DS_Store$">>],
              <<"interval">> => 3600000,
              <<"path">> => <<"/home/ferd/revault-docs/music/">>}},
  <<"peers">> => #{},
  <<"server">> =>
      #{<<"auth">> =>
            #{<<"tls">> =>
                  #{<<"authorized">> => #{},
                    <<"certfile">> => <<"/home/ferd/.config/ReVault/certs/alpha.crt">>,
                    <<"keyfile">> => <<"/home/ferd/.config/ReVault/certs/alpha.key">>,
                    <<"port">> => 8022,<<"status">> => enabled}}}}
```

Everything seems alright, and you can see that by default the app ignores the `.DS_Store` files that MacOS keeps generating because synchronizing them is meaningless.

Let's scan the files:

```
$ ./_build/prod/bin/revault_cli scan
Scanning music: {badrpc,
    {'EXIT',
        {noproc,
            {gen_server,call,
                [{via,gproc,{n,l,{revault_dirmon_event,<<"music">>}}},
                 force_scan,infinity]}}}}
...
```

Weird, the thing doesn't exist. It turns out ReVault is lazy and will only boot a process if something could ever talk to it. Since TLS synchronizing has peer-specific matching and we specified no peers, there's nothing to boot. We can cheat a bit for that by temporarily turning on the TCP server, but you can also wait until we bootstrap a peer:

```toml
# ... rest of the config file

[server.auth.tls.authorized]
    ## no one can access us yet

[server.auth.none]
    # status = "disabled"
    port = 9999
    sync = ["music"]
```

Now if we restart and try again:

```
$ ./_build/prod/bin/revault_cli scan
Scanning music: ok
$ ls /home/ferd/revault-docs/revault/db/music # show internal metadata
id  tracker.snapshot  uuid
```

We're good to go. Remember to disable the TCP server by removing the config entry.

## Bootstrapping a Peer

At this point in time, we won't accept connections from anyone and we used a quick hack to work around it (which I should really make sure we don't need, that's janky). So what we'll do is start a regular peer, first by connecting directly to the server, and later by using the server to seed some state we can upload to a remote host.

For the sake of this demonstration, we are going to run multiple peer nodes from the same host. To do so, you'll see me override the `NODENAME` environment variable. Its default value is `revault`. Changing it means we'll need to pass a few extra arguments in the command line and duplicate some configuration values but otherwise everything is the same.

### By Connecting to a Server

We're gonna need to first bootstrap a new peer by creating a new config file for it at `/home/ferd/.config/ReVault/config_peer_a.toml`:

```toml
[db]
  path = "/home/ferd/revault-docs/revault/db_beta/"

[dirs]
  [dirs.music]
  interval = 3600
  path = "/home/ferd/revault-docs/music_beta/"

[peers]
    [peers.alpha]
    sync = ["music"]
    url = "127.0.0.1:8022"
        [peers.alpha.auth]
        type = "tls"
        certfile = "/home/ferd/.config/ReVault/certs/beta.crt"
        keyfile = "/home/ferd/.config/ReVault/certs/beta.key"
        peer_certfile = "/home/ferd/.config/ReVault/certs/alpha.crt"
```

Make sure the right directories are in place, and create the keys with the CLI tool (`./_build/prod/bin/revault_cli generate-keys -path "/home/ferd/.config/ReVault/certs/" -name beta`), so everything is in place.

You can already start the new peer on its own terminal:

```
$ REVAULT_CONFIG=/tmp/config/config_beta.toml NODENAME=beta _build/prod/rel/revault/bin/revault console
(beta@ferd.local)1>
```
if you try scanning right now, it will fail. The app can't scan until it has an ID and an app in client mode won't have an ID until it is seeded. To seed it, you'd need to call the proper command:

```
$ ./_build/prod/bin/revault_cli remote-seed -dirs music -node beta@ferd.local -peer alpha
Seeding music from revault: {error,sync_failed}
```

The problem, of course, is that our initial node does not accept connections. Let's add the following to its configuration:

```toml
# ... rest of the file elided ...
[server.auth.tls.authorized]
    [server.auth.tls.authorized.beta]
    # each peer should have a unique peer certificate to auth it
    certfile = "/home/ferd/.config/ReVault/certs/beta.crt"
    sync = ["music"]

```

This explicitly allows the `beta` certificate to synchronize the music directory.  Restart the initial node and retry seeding. It should look like the following:

```
$ ./_build/prod/bin/revault_cli remote-seed -dirs music -node beta@ferd.local -peer alpha
Seeding music from alpha: ok
$ ./_build/prod/bin/revault_cli scan -dirs music -node beta@ferd.local
Scanning music: ok
```

Note here that the peer name refers to the name written in the config (`alpha`). That name can be anything and is different from the `NODENAME` variable (which would be `revault@ferd.local` for the `alpha` peer).

The node is now running, and can be [synchronized](#synchronizing-files)!

### By Command Line Seeding

The previous procedure works well when the new node can connect to the old node to get its initial metadata. It, however, doesn't work well when the new node can only be connected to but can't initiate connections the other way.

This is a common pattern when you initialize the first node on your own computer, and want to synchronize with a new remote server that won't be able to connect to your home network. The `seed` command is useful for this:

```
$ ./_build/prod/bin/revault_cli seed --help
usage: revault-cli seed [-node <node>] [-path <path>] [-dirs <dirs>...]

Optional arguments:
  -node ReVault instance to connect to and from which to fork. Must be local. (string re: .*@.*, revault@ferd.local)
  -path path of the base directory where the forked data will be located. (string, ./forked/)
  -dirs Name of the directories to fork. (binary)
```

You can just call `revault_cli seed -path /tmp/forked -dirs music` and it's going to work, but in ReVault, any node can act as either a server or a client. Here's an example where our previous `beta` node is going to be used to seed the metadata:

```
$ ./_build/prod/bin/revault_cli seed -path /tmp/forked -dirs music -node beta@ferd.local
Seeding music in "/tmp/forked": ok
$ ls /tmp/forked
music
$ ls /tmp/forked/music
id  uuid
```

These two files are the basic requirement to act as a server before even scanning files. If you recall what happened when we showed metadata earlier, it looked like this:

```
$ ls /home/ferd/revault-docs/revault/db/music # show internal metadata
id  tracker.snapshot  uuid
```

You can see the path of the metadata directory being `db/$DIR` and having it contain both the `id` and the `uuid` files (`tracker.snapshot` exists only after having scanned files and should _not_ be used to seed a new host, and isn't included).

Basically, you put the two "seed" files in the internal metadata directory of the remote host (through say `sftp` or`scp`) and when it boots it will have enough information to do everything without conflicting with other peers.

## Synchronizing Files

Assuming your hosts are all set up fine according to prior instructions, you can just synchronize them by using the CLI tool:

```
$ ls /tmp/revault-docs/music_beta/

$ ./_build/prod/bin/revault_cli sync -dirs music -node beta@ferd.local -peer alpha
Scanning music: ok
Syncing music with alpha: ok
$ ls /tmp/revault-docs/music_beta/
cool.mp3
```

By default, the `node` value is `revault@your.local.hostname` (the default host name ReVault will pick without custom values), so most commands actually look like this:

```
$ ./_build/prod/bin/revault_cli sync -dirs music -peer alpha
Scanning music: ok
Syncing music with alpha: ok
```

### Dealing with Conflicts

Whenever two peers are believed to concurrently have edited two files in incompatible ways (they have different hashes) _at the same logical time_, we have a conflict.

What do we mean by logical time? Let's imagine two nodes, A and B, talking to each other.

If a user writes file a.txt to A, and then synchronizes it to B, now both A and B have a.txt with the same content. If the user then modifies a.txt on B and then synchronizes with A, both A and B are still in agreement with the newest file on both.

If a user now writes file b.txt containing `1` on B, synchronizes it to A, both nodes have the same file with the same value. Now, however, let's assume that our user modifies the b.txt so it contains `this is A` on A, and `this is B` on B, _without synchronizing them_. We now have a divergence where b.txt is known by both hosts, had a past agreement, but no longer does.

So if we synchronize _then_, we can't pick a winning version: both happened independently.

ReVault does not make a choice here: it surfaces the conflict. Rather than having `b.txt`, the directory will now contain the following files:

```
# the "working file" is the latest local known file
b.txt =>
    this is B
# a marker file, which contains the hashes of all conflicting files
b.txt.conflict =>
    2159C7BCEC9B2A59BB291A2108839F692DAAC0C69DDFAD51D65C4F75964C6742
    D8AD1BDC045122DE6698503A76D6DE22E0C51F6BF331B52FB41C6E29F9F2E770
b.txt.2159C7BC =>
    this is A
b.txt.D8AD1BDC =>
    this is B
```
If you synchronize with another peer (say, C), the conflict will be propagated _as is_. If C had also received a conflicting edit, its conflict will be expanded to other peers as well.

To resolve the conflict, edit the working file (`b.txt`). Once you are satisfied with its content, delete the marker file (`b.txt.conflict`) and either `scan` or `sync` the directory. This will resolve the conflict, and whatever was in `b.txt` at scan time is considered to be the conflict winner, which will be propagated on next synchronizations.

If you delete `b.txt` along with deleting `b.txt.conflict`, ReVault assumes you resolve the conflict by deleting the file (ReVault can detect situations where A modifies a file while B deletes it and both are technically conflicts!)

## Configuring OTel

I've only tested this with https://honeycomb.io:

```
$ OTEL_EXPORTER_OTLP_TRACES_ENDPOINT="https://api.honeycomb.io" \
  OTEL_EXPORTER_OTLP_HEADERS="x-honeycomb-team=$YOUR_INGEST_KEY,x-honeycomb-dataset=ReVault" \
  OTEL_SERVICE_NAME="ReVault" \
  OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
  ./_build/prod/rel/revault/bin/revault console
```

This will automatically start publishing events for synchronization to your Honeycomb team, no collector required or anything (ReVault uses the Erlang OTel distribution which runs its own collector if configured).

TODO: cover useful queries at this point in time

## Using S3 as a back-end

TODO: make friendlier docs, this is more of a stream of a sparse list of elements.

ReVault uses AssumeRole as a way to make anything work.

I suggest making a `ReVault` user with no console access. Once your host is authenticated with it, make sure you have the following Role Policy under the role `ReVault-s3`:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "VisualEditor0",
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:GetObjectAttributes",
                "s3:ListBucket",
                "s3:DeleteObject"
            ],
            "Resource": [
                "arn:aws:s3:::revault-bucket",
                "arn:aws:s3:::revault-bucket/*"
            ]
        }
    ]
}
```

And give it the following trust policy:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "Statement1",
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::<ID>:user/ReVault"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
```

Basically, we define a role that can write to a specific S3 bucket within the account, and give a single user the permission to use it during role sessions.

When ReVault is configured with a file like follows, it will have an S3 back-end—it won't write to disk, only to the S3 bucket, using the custom role with temporary sessions:

```toml
[db]
  path = "revault/db/"

# This is the part that makes it all go on S3
[backend]
  mode = "s3"
  role_arn = "arn:aws:iam::<ID>:role/ReVault-s3"
  region = "us-east-2"
  bucket = "revault-bucket"

# This is config as usual
[dirs]
  [dirs.music]
  interval = 604800 # 1 week
  path = "revault-docs/music"

[peers]
    [peers.alpha]
    sync = ["music"]
    url = "127.0.0.1:8022"
        [peers.alpha.auth]
        type = "tls"
        certfile = "/home/ferd/.config/RevAult/certs/s3.crt"
        keyfile = "/home/ferd/.config/ReVault/certs/s3.key"
        peer_certfile = "/home/ferd/.config/RevAult/certs/alpha.crt"

[server]
    [server.auth.tls]
    # status = "disabled"
    port = 8023
    certfile = "/home/ferd/.config/RevAult/certs/s3.crt"
    keyfile = "/home/ferd/.config/ReVault/certs/s3.key"
    [server.auth.tls.authorized]
        [server.auth.tls.authorized.alpha]
        # each peer should have a unique peer certificate to auth it
        certfile = "/home/ferd/.config/RevAult/certs/alpha.crt"
        sync = ["music"]
```

In this case, the S3 host can act both as a client and as a server. It can be synchronized to and scan as usual with the CLI, and will use SSH like everything else.

Also it's worth pointing out that while the node won't use the local disk for any file or metadata writes, it needs the config file and certificates to be local.
