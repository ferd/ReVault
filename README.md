ReVault
=====

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

Roadmap
---

See the [https://github.com/ferd/ReVault/projects](Project boards)

Why the ReVault name?
---

It's a bad pun between a file vault, not wanting a paying service where a third party gets to hold copies of my files, and having no master (nodes).

Build
-----

    $ rebar3 as prod release

Tests
---

    $ rebar3 check
