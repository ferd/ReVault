ReVault
=====

[![CircleCI](https://circleci.com/gh/ferd/ReVault.svg?style=svg)](https://circleci.com/gh/ferd/ReVault)

ReVault is a peer-to-peer self-hosted file synchronization project.

The main goal of the project is to allow seemless, mostly-offline, and transparent update of directories and files whenever possible. Basically, provide something that could be a bit of a DropBox alternative where you don't actually have to set anything up with a third party to work, and that could work as well between all-local computers, or using a laptop and a VPS.

Rationale
---

This is a side project done for fun and because I find it useful. It's non-trivial to get right, but I do not want to turn this into a business or a full-time job, and I am interested in getting collaboration from all kinds of interested parties without limiting who can use it too much (hence the LGPL 3.0 license).

Currently, there's little code written. I've had various sample apps where I tried to build the same thing and mostly focused on the synchronization mechanism but had nothing available. For this project, I decided to take an open approach over GitHub, using projects and boards to have an entirely open process to see how it goes.

Approach
---

Move slow and don't break things. Backward compatibility is going to be a possibility, but changes to this code should be done:

- Ethically: no backdoors, safe by default settings, with limitations clearly exposed. Developer logs should be anonymized by default to prevent leaking undue information
- With a concern for Quality: no files should be lost or corrupted, and this project should be able to act as an example good Erlang application for the community
  - solid unit tests
  - comprehensive property-based tests
  - type checks
  - linting
  - commented code
- An Emphasis on Clarity: things should be well-documented, and the software should aim to cause no undue user surprises
- Invisible: while you may need somewhat technical knowledge to set things up, it should require no special knowledge to have the software running over your regular directories
- Operable: layered and structured logs, with a clear concern and distinction between what the user wants to know when debugging, and what developers want to know when debugging
- Respectfully: there is a code of conduct which I (@ferd) will enforce strictly. I will obviously not kick myself out of my repository, but will expect call-outs when/if misbehaving, and will accept forks without a complaint on my part

Invariants to Maintain
---

- Never modify a file that a user created other than by synchronization
- a "dry run" mode cannot touch the tracked directory's filesystem
- security is critical (ensure to lock down EPMD, do proper SSH validation, etc.)
- correctness over performance
- be portable across Linux, OSX, and Windows (at various efficiency costs)

Using
-----

Specify some configuration. By default, we look into your home directory for
a `ReVault/config.toml` file (using the XDG standard of `~/.config/ReVault/config.toml` on both Linux and OSX). The format of the config file is:

```
[db]
  path = "/Users/ferd/.config/ReVault/db/"

[dirs]
  [dirs.music]
  interval = 60
  path = "~/Music"
  
  [dirs.images]
  interval = 60
  path = "/Users/ferd/images/"
  ignore = [] # regexes on full path

[peers]
  # VPS copy running
  [peers.vps]
  sync = ["images"]
  url = "leetzone.ca:8022"
    [peers.vps.auth]
    type = "ssh"
    cert = "~/.ssh/id_rsa"

  # Localhost copy running
  [peers.local]
  url = "localhost:8888"
    [peers.local.auth]
    type = "none"

[server]
    [server.auth.none]
    port = 9999
    sync = ["images", "music"]
    mode = "read/write"

    [server.auth.ssh]
    status = "disabled"
    port = 8022
    [server.auth.ssh.authorized_keys]
        [server.auth.ssh.authorized_keys.vps]
        public_key = "...."
        sync = ["images", "music"]

        [server.auth.ssh.authorized_keys.friendo]
        public_key = "...."
        sync = ["music"]
        mode = "read"
```

The file path can be overridden by using environment variables, calling the release with arguments such as:

```
./_build/default/rel/revault/bin/revault console -revault config '"some/path"'
```

Note the nested quoting around the path. A helper script hiding this implementation detail should eventually be added.

Roadmap
---

See the [Project boards](https://github.com/ferd/ReVault/projects)

Why the ReVault name?
---

It's a bad pun between a file vault, not wanting a paying service where a third party gets to hold copies of my files, and having no master (nodes).

Build
-----

    $ rebar3 as prod release

Tests
---

    $ rebar3 check

