# Danku 断空

[![ci](https://github.com/houssemMekhelbi/danku/actions/workflows/ci.yml/badge.svg)](https://github.com/houssemMekhelbi/danku/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> *Danku* (断空, "severing the void") is the barrier spell in *Bleach* that stops an attack cold.
> This one stands between an AI agent and the rest of your machine.

**Run AI coding agents on real projects without handing them your machine.**

```sh
danku claude ~/projects/shop
```

That one command starts Claude Code (or Codex, or pi) in a rootless Podman container. The agent
sees one project directory, reaches the internet only through an allowlist proxy, and cannot gain
privileges. When it needs a database, it writes a compose file; a policy guard checks that file
before the host runs anything.

The project is one Bash launcher, one Python policy guard, a proxy image and three harness images.
There's no daemon and nothing runs as root.

## Why

A coding agent runs shell commands with your user's rights. It reads every README, issue and
dependency it is pointed at, and any of those can carry instructions. Approving each command by hand
doesn't scale. So the agent gets to work freely, inside a box that limits what a bad instruction can
reach:

- **Your files.** It can't read `~/.ssh`, browser profiles, cloud credentials or your other projects.
- **The network.** It can't send your code or secrets to an arbitrary host.
- **Your host.** It can't install anything outside the container, escalate privileges, or start
  privileged containers through compose.

## How it works

```
host · rootless podman · your uid
│
├── session      danku-claude-shop-<pid>
│     read-only rootfs · cap-drop=all · no-new-privileges · pids + memory limits
│     /workspace/shop  ◄── ~/projects/shop            (rw, the only project mounted)
│     /home/agent      ◄── $DANKU_STATE/claude/home      (rw, logins and history)
│     network: internal, no DNS ── HTTP(S)_PROXY ──┐
│                                                  ▼
├── proxy        danku-claude-shop-<pid>-proxy   tinyproxy · read-only · cap-drop=all
│     default deny · allowlisted hosts and ports only ──► internet
│     allowlist = proxy/allowlist + shop/.danku/allow, built per session
│
└── stack        danku-shop   (optional: postgres, redis, ...)
      compose file written by the agent ─► compose-guard.py ─► podman-compose on the host
      internal networks only · ports on 127.0.0.1 · bind mounts inside the project
```

1. **Path vetting.** The project path is resolved through symlinks and must land below `DANKU_ROOTS`.
   `$HOME`, the state directory, `~/.ssh`, `~/.gnupg` and `~/.config/gh` are refused even if a
   symlink points at them.
2. **A proxy per session.** Each session gets a private `--internal` network with DNS disabled, so
   the only route out is its own proxy. The proxy forwards only to allowlisted hosts, tunnels only
   to allowlisted ports, and is torn down with the session.
3. **Locked-down container.** Read-only root filesystem, every capability dropped,
   `no-new-privileges`, a non-root user mapped to your uid, a `noexec` `/tmp`, and pids and memory
   limits (hard, plus a soft limit that reclaims memory first).
4. **Per-project images.** `.danku/apt` and `.danku/pip` are baked into an image tagged by content hash.
   It is built once and reused, so the session never needs root at runtime.
5. **A guard for compose stacks.** The agent may write `compose.yaml`, but only you start it, with
   `danku compose`. The guard resolves the file with `podman-compose config` and then works as follows:
   - **Refused:** `privileged`, `cap_add`, `devices`, `security_opt`, host namespaces, `build`,
     external networks and volumes, and bind mounts disguised as volume `driver_opts`.
   - **Rewritten:** ports bind to 127.0.0.1, every network becomes internal, and memory and pids
     limits are set.
   - **Result:** nothing runs unless every rule passes.

## Quick start

Requirements: Linux, rootless Podman, `podman-compose` and PyYAML (for `danku compose`), and `socat` (for `danku port`).

```sh
git clone https://github.com/houssemMekhelbi/danku && cd danku
ln -s "$PWD/danku" ~/.local/bin/danku
danku build                                    # base, claude, codex, pi and proxy images
mkdir -p ~/.local/share/danku/claude/home      # the harness home; log in once inside
danku claude ~/projects/shop                   # start working
```

```sh
danku pi ~/projects/shop --resume              # anything after the project goes to the harness
danku shell claude ~/projects/shop -c 'npm test'   # same sandbox, a shell instead of the agent
danku compose ~/projects/shop up               # the project's own stack, guarded
danku ports shop && danku port shop 5173          # reach a dev server from the host browser
danku help                                     # every command and topic
```

## Configuration

Per project, in `<project>/.danku/` (all optional, read at session start):

| File | Effect | Example |
|---|---|---|
| `allow` | extra hosts the agent may reach (ERE per line) | `^api\.stripe\.com$` |
| `ports` | extra outgoing CONNECT ports (443 is always allowed) | `8443` |
| `apt`, `pip` | packages baked into the cached project image | `postgresql-client` |
| `mask` | subdirectories hidden behind an empty read-only tmpfs | `secrets` |
| `publish` | ports published on host 127.0.0.1 at start | `3000` |
| `ssh-agent` | empty file: the agent may ask your ssh-agent to sign, never read a key | |

Project secrets go in `$DANKU_STATE/projects/<name>/env` (`KEY=value`). The file sits outside the
project, so the agent can use the secrets but can't edit the file.

Global settings come from the environment:

| Variable | Default | |
|---|---|---|
| `DANKU_ROOTS` | `~/projects` | `:`-separated; projects must resolve below one of them |
| `DANKU_STATE` | `~/.local/share/danku` | harness homes and per-project env files |
| `DANKU_LLAMA_URL` | unset | a local model server (e.g. llama.cpp), exported as `LLAMA_URL` |
| `DANKU_MEM` | `16g` | session memory limit |

The global allowlist, `proxy/allowlist`, covers the Anthropic and OpenAI APIs and the npm, PyPI and Maven registries.

## Tests

```sh
python3 -m unittest discover -s tests   # compose-guard policy: 15 tests, no podman needed
tests/compose-test.sh                   # end to end on the host
```

The end-to-end test feeds the guard a deliberately hostile compose file and checks each expected
refusal. Then it brings up Postgres and a web service next to a live session and checks the following:
- service names resolve inside the session;
- allowlisted APIs still answer through the proxy;
- direct egress is blocked from both the session and the stack;
- published ports listen on 127.0.0.1 only.

CI runs shellcheck and the unit tests on every push.

## Limits

- **It is a container, not a VM.** It shares the host kernel, so a kernel exploit is out of scope.
- **The agent has full rights inside its project.** Keep the project in git and review diffs.
- **The agent can read its own harness credentials** (the API login in its home).
- **The agent can edit `<project>/.danku/`**, and the changes apply at the next session start. Review
  `git diff .danku` before starting one; making `.danku/` read-only inside the session is planned.
- **The allowlist works on host names.** An allowed host that serves arbitrary content (a package
  registry, for instance) can still deliver anything.

## License

[MIT](LICENSE)
