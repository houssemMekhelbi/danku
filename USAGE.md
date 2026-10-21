# danku — quick usage

Script: `<repo>/danku` (on PATH as `danku`). Run it on the **host**, never from inside a session.

## Run

```sh
danku claude ~/projects/foo          # Claude Code in the sandbox
danku codex  ~/projects/foo
danku pi     ~/projects/foo
danku claude ~/projects/foo --resume  # anything after the dir goes to the harness
danku shell claude ~/projects/foo     # same sandbox, bash instead (to poke around)
danku shell claude ~/projects/foo -c 'npm test'   # one command, then exit
danku build                                    # rebuild images (after editing a Containerfile / version bump)
```

Inside the session:

| What | Where |
|---|---|
| your project (read-write) | `/workspace/<dir-name>` |
| home of the agent | `/home/agent` = host `$DANKU_STATE/<harness>/home` (logins live here) |
| everything else of yours | not visible |
| local model server | `$LLAMA_URL`, when `DANKU_LLAMA_URL` is set on the host |
| am I sandboxed? | `echo $DANKU_SANDBOX` → `1` |

## Paths: which projects are allowed

- Any dir under `$DANKU_ROOTS` (default `~/projects`) works (symlinks are followed, the real path must be under it).
- Somewhere else, one time: `DANKU_ROOT=/data danku claude /data/thing`
- Always somewhere else: `export DANKU_ROOTS=~/projects:/data`.
- Always refused: `~` itself, `$DANKU_STATE`, `~/.ssh`, `~/.gnupg`, `~/.config/gh`.
- Hide a subfolder of the project from the agent: put its relative path in `.danku/mask` (one per line, e.g. `secrets`).

## Per-project config: `<project>/.danku/`

Create the folder, add only the files you need. **Changes apply at the next session start**: quit and rerun `danku ...`.

| File | Effect | Example line |
|---|---|---|
| `allow` | extra sites the agent may reach (regex, one per line) | `^github\.com$` |
| `ports` | extra outgoing HTTPS ports (443 already allowed) | `8443` |
| `publish` | fixed ports opened on host `127.0.0.1` (server must listen on `0.0.0.0`) | `3000` |
| `apt` | Debian packages baked into the image | `postgresql-client` |
| `pip` | Python packages (into `/opt/venv`) | `requests` |
| `mask` | subdirs hidden inside the sandbox | `secrets` |
| `ssh-agent` | empty file: the agent may *sign* with your loaded ssh keys | (empty) |

API keys / tokens for the project: `$DANKU_STATE/projects/<dir-name>/env` with `KEY=value` lines. They show up as env vars inside. That file is never in the project, so the agent can't edit it.

### Add / remove a permission

```sh
cd ~/projects/foo
mkdir -p .danku
echo '^api\.stripe\.com$' >> .danku/allow     # add a site
sed -i '/stripe/d' .danku/allow               # remove it
rm .danku/ssh-agent                           # revoke ssh signing
```

Allowed for **all** projects: `proxy/allowlist` (Anthropic, OpenAI, npm, PyPI, Maven). Edit, then restart the sessions.

Is a site blocked? Inside: `curl -v https://site` → `CONNECT tunnel failed, response 403` = not on the allowlist.

> Until the security fixes land, the agent can write `.danku/` itself. Check `git diff .danku` / `cat .danku/*` before you start a session.

## Dev server: open the app from the host

**Port known in advance** (server must listen on `0.0.0.0`, e.g. `vite --host`, `next dev -H 0.0.0.0`):

```sh
echo 3000 >> ~/projects/foo/.danku/publish
danku claude ~/projects/foo
# browser on host: http://127.0.0.1:3000
```

**Port not known / server only listens on localhost** (session already running, second terminal):

```sh
danku ports foo            # list ports listening inside the session
danku port foo 5173        # host 127.0.0.1:5173 -> session :5173   (Ctrl-C stops)
danku port foo 5173 8080   # same, but on host port 8080
```

If several sessions of `foo` are running, `danku port`/`danku ports` refuse; close the extras.

## Test an API

```sh
# inside the session (agent or danku shell)
curl http://localhost:8000/health
# from the host, after publish or `danku port`
curl http://127.0.0.1:8000/health
```

## From the phone / another machine on the tailnet

Ports only open on `127.0.0.1`. Share one over the tailnet from the host (tailnet only, not the internet):

```sh
tailscale serve --bg 3000     # https://<host>.<tailnet>.ts.net -> 127.0.0.1:3000
tailscale serve status
tailscale serve reset         # stop sharing
```

`tailscale funnel` makes it public on the internet. Don't use it for dev servers.

## Databases and services: compose

The agent writes `compose.yaml` in the project. **You** start it from the host:

```sh
danku compose foo check      # validate only (paths inside project, no privileges, ports -> 127.0.0.1)
danku compose foo up         # start; running sessions join its network
danku compose foo ps | logs [svc] | restart [svc]
danku compose foo down       # stop (add -v to delete volumes)
```

- From the session, services answer by name: `db:5432`, `http://web:8000`.
- From the host: whatever `ports:` says, always on `127.0.0.1` (e.g. `127.0.0.1:15432:5432` → `psql -h 127.0.0.1 -p 15432`).
- The services have no internet.

## Git

- Commit inside the session: yes (name/email come from your git config).
- Push: from the host (GitHub is not on the allowlist, and the sandbox has no direct network).

## When something breaks

| Message | Do |
|---|---|
| `... not below any of: ~/projects` | `DANKU_ROOT=<parent dir> danku ...` |
| `refusing to mount ...` | that's home, $DANKU_STATE or a key dir; pick a project subdir |
| `missing $DANKU_STATE/<h>/home` | `mkdir -p` it, start the session, log in there once |
| image not found / `--pull=never` error | `danku build` |
| site unreachable inside | add it to `.danku/allow`, restart the session |
| `no running session for foo` | start one first; `foo` = project dir name |
| `danku compose: refused ...` | read the listed lines, fix `compose.yaml`, `danku compose foo check` |

Full check of compose + networking: `tests/compose-test.sh` (run on host).
