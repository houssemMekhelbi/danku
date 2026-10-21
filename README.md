# agent-sandbox

Run AI coding agents (Claude Code, Codex, pi) on real projects without giving them your machine.

`ai claude ~/projects/foo` starts the agent in a rootless Podman container that can see one project
directory, can reach only an allowlist of hosts, and cannot gain privileges. One Bash launcher, one
Python policy guard, a proxy image and three harness images.

```
host (rootless podman)
├── session container  ai-claude-foo-<pid>
│     read-only rootfs · cap-drop=all · no-new-privileges · pids + memory limits
│     mounts: ~/projects/foo → /workspace/foo (rw)    harness home → /home/agent (rw)
│     network: internal, no DNS ──► HTTP(S)_PROXY only
│
├── proxy container  ai-claude-foo-<pid>-proxy   (tinyproxy, read-only, cap-drop=all)
│     default deny · CONNECT to allowlisted hosts and ports only
│     allowlist = proxy/allowlist + <project>/.ai/allow
│
└── optional compose stack  ai-foo  (db, redis, ...)
      agent-written compose file, validated by compose-guard.py before the host runs it
      internal networks only · ports on 127.0.0.1 · paths inside the project
```

## Threat model

The agent is treated as a well-meaning process that can be steered by untrusted input: a README,
an issue, a dependency, a web page. The sandbox limits what it can reach, not what it can think.

| The agent cannot | Because |
|---|---|
| read `~/.ssh`, browser profiles, other projects, cloud credentials | only the project and the harness home are mounted; `$HOME`, the state dir and key dirs are refused even through symlinks |
| send data to an arbitrary host | the session network is `--internal` with no resolver; the only way out is the per-session proxy, which denies by default |
| modify the image or install a rootkit | read-only root filesystem, `--cap-drop=all`, `no-new-privileges`, rootless user namespace |
| fork-bomb or exhaust memory | `--pids-limit`, hard and soft memory limits |
| escape through a compose file it wrote | `compose-guard.py` refuses privileged keys, host namespaces, devices, external resources, bind mounts outside the project (also disguised as volume `driver_opts`), and rebinds every port to 127.0.0.1 |
| use your SSH keys | by default no agent socket; with `.ai/ssh-agent` it can ask the agent to sign, never read a key |

Out of scope: it is a container, not a VM, so it shares the host kernel. The agent can still damage
the project it was given (use git) and can read its own harness credentials.

## Use

```sh
./ai build                                 # base, harness and proxy images
mkdir -p ~/.local/share/ai/claude/home     # harness home: logins and history live here
./ai claude ~/projects/foo                 # Claude Code, sandboxed
./ai pi ~/projects/foo --resume            # anything after the project goes to the harness
./ai shell claude ~/projects/foo -c 'npm test'
./ai compose ~/projects/foo up             # the project's own compose stack, fenced
./ai help                                  # commands and topics
```

Per-project settings live in `<project>/.ai/`: `allow` (extra hosts), `ports`, `apt` and `pip`
(packages baked into a cached project image), `mask` (subdirs hidden from the agent), `publish`
(ports on 127.0.0.1), `ssh-agent`. Secrets for a project go in `$AI_STATE/projects/<name>/env`,
outside the project, so the agent cannot edit them. See [USAGE.md](USAGE.md).

| Setting | Default |
|---|---|
| `AI_ROOTS` | `~/projects` (`:`-separated; projects must resolve below one of them) |
| `AI_STATE` | `~/.local/share/ai` |
| `AI_LLAMA_URL` | unset; a local model endpoint (e.g. llama.cpp), exported as `LLAMA_URL` |
| `AI_MEM` | `16g` |

## Tests

```sh
python3 -m unittest discover -s tests   # compose-guard policy, no podman needed
tests/compose-test.sh                   # end to end on the host: refusals, rewrites, isolation, egress
```

The end-to-end test starts its own session and a Postgres + web stack, then checks that service
names resolve inside the session, that allowlisted APIs still work through the proxy, and that
direct egress from the session and from the stack is blocked.

## License

MIT
