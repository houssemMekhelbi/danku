# shellcheck shell=bash
# Help for `ai`, sourced by ai only when help is asked for.
#   ai help                 overview
#   ai help <command>       run shell build ports port compose
#   ai help <topic>         paths allow config packages secrets dev api tailnet git errors
#   ai <command> -h         same as ai help <command>

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then B=$'\e[1m' D=$'\e[2m' C=$'\e[36m' R=$'\e[0m'; else B='' D='' C='' R=''; fi

help_overview() {
  cat <<EOF
${B}ai${R} — run claude / codex / pi in a podman sandbox (run on the host)

${B}COMMANDS${R}
  ${C}ai claude|codex|pi <dir> [args]${R}       start a sandboxed session on a project
  ${C}ai shell <harness> <dir> [cmd]${R}        same sandbox, bash instead of the harness
  ${C}ai ports <project>${R}                    ports listening inside the running session
  ${C}ai port <project> <port> [host-port]${R}  open a session port on host 127.0.0.1
  ${C}ai compose <project> <verb>${R}           run the project's compose stack (db, redis, ...)
  ${C}ai build${R}                              rebuild the images
  ${C}ai help [command|topic]${R}               this help

${B}TOPICS${R}  ${D}(ai help <topic>)${R}
  paths      which project dirs are allowed, hiding subfolders
  allow      let the agent reach a site / port, and take it back
  config     every file in <project>/.ai/
  packages   apt and pip packages in the project image
  secrets    API keys and tokens for a project
  dev        open the app running in the session from your browser
  api        test an API from inside and from the host
  tailnet    reach a dev server from the phone / another machine
  git        commit inside, push outside
  errors     common messages and what to do

${B}QUICK${R}
  ai claude ~/projects/foo
  echo '^api\.stripe\.com\$' >> ~/projects/foo/.ai/allow   ${D}# then restart the session${R}
  ai ports foo && ai port foo 5173                                  ${D}# then http://127.0.0.1:5173${R}
EOF
}

help_run() {
  cat <<EOF
${B}ai claude|codex|pi <dir> [harness args...]${R}

Start the harness in a sandbox on <dir>. Everything after <dir> goes to the harness.

  ai claude ~/projects/foo
  ai claude ~/projects/foo --resume
  ai pi .

${B}Inside the session${R}
  /workspace/<dir-name>   the project, read-write
  /home/agent             host ~/.local/share/ai/<harness>/home (logins are kept here)
  \$LLAMA_URL              llama-router on the host
  \$AI_SANDBOX=1           you are sandboxed
  The rest of your home, ssh keys, podman, gh: not there.
  Network: only the sites in the allowlist, through a proxy (see: ai help allow).

${B}Options${R} ${D}(environment)${R}
  AI_ROOT=<dir>   allow a project outside AI_ROOTS for this run (see: ai help paths)
  AI_NOTTY=1      no terminal (scripts, pipes)
EOF
}

help_shell() {
  cat <<EOF
${B}ai shell <claude|codex|pi> <dir> [cmd...]${R}

The same sandbox as the harness would get, but bash. Use it to check what the agent can see or reach.

  ai shell claude ~/projects/foo                 ${D}# interactive${R}
  ai shell claude ~/projects/foo -c 'npm test'   ${D}# one command${R}
  ai shell pi . -c 'curl -v https://github.com'           ${D}# is a site allowed?${R}
EOF
}

help_build() {
  cat <<EOF
${B}ai build${R}

Rebuild ai-base, ai-claude, ai-codex, ai-pi and ai-proxy. Needed after editing a Containerfile
(e.g. a harness version bump in <harness>/Containerfile) or proxy/tinyproxy.conf.

Project images (from .ai/apt, .ai/pip) build by themselves at session start when the files change.
EOF
}

help_ports() {
  cat <<EOF
${B}ai ports <project>${R}

List the TCP ports listening inside the running session of <project> (dir name, e.g. foo).

  ai ports foo
    foo:
       5173  loopback only
       8000  all interfaces

Then open one with: ai port foo 5173
EOF
}

help_port() {
  cat <<EOF
${B}ai port <project> <port> [host-port]${R}

Forward host 127.0.0.1:<host-port> (default: same) to <port> in the running session.
Works even when the server listens only on localhost. Stays in the foreground; Ctrl-C stops it.

  ai port foo 5173          ${D}# http://127.0.0.1:5173${R}
  ai port foo 5173 8080     ${D}# http://127.0.0.1:8080${R}

Fixed port every time instead: ai help dev
EOF
}

help_compose() {
  cat <<EOF
${B}ai compose <project> check|up|down|ps|logs|restart [service...]${R}

The agent writes compose.yaml in the project; you start it on the host. The file is checked first
(paths inside the project, no privileges, ports on 127.0.0.1, no internet for services).

  ai compose foo check          ${D}# validate only${R}
  ai compose foo up             ${D}# start; running sessions join its network${R}
  ai compose foo logs db
  ai compose foo restart web
  ai compose foo down           ${D}# stop; add -v to also delete volumes${R}

From the session: services by name      db:5432, http://web:8000
From the host:    the ports: mapping    "15432:5432" -> psql -h 127.0.0.1 -p 15432
EOF
}

help_paths() {
  cat <<EOF
${B}Which project dirs are allowed${R}

  Under AI_ROOTS            always (symlinks are followed; the real path must be under it)
  Somewhere else, once      AI_ROOT=/data ai claude /data/thing
  Somewhere else, always    AI_ROOTS=~/projects:/data (colon-separated)
  Never                     ~ itself, ~/.local/share/ai, ~/.ssh, ~/.gnupg, ~/.config/gh

${B}Hide part of a project${R}
  echo secrets >> <project>/.ai/mask     ${D}# relative dir; shows up empty inside${R}
EOF
}

help_allow() {
  cat <<EOF
${B}Let the agent reach a site${R}  ${D}(applies at the next session start: quit and rerun ai)${R}

  cd ~/projects/foo && mkdir -p .ai
  echo '^api\.stripe\.com\$'  >> .ai/allow      ${D}# one site (regex, anchor it with ^ and \$)${R}
  echo '^([a-z0-9-]+\.)*githubusercontent\.com\$' >> .ai/allow   ${D}# a site and its subdomains${R}
  echo 8443 >> .ai/ports                        ${D}# a non-443 HTTPS port${R}

${B}Take it back${R}
  sed -i '/stripe/d' .ai/allow
  rm .ai/ssh-agent                              ${D}# stop ssh signing${R}

${B}For every project${R}
  proxy/allowlist   (Anthropic, OpenAI, npm, PyPI, Maven). Edit, restart sessions.

${B}Is it blocked?${R}
  inside: curl -v https://site   ->  "CONNECT tunnel failed, response 403" = not allowed

${D}Until the security fixes land the agent can edit .ai/ itself: check  cat .ai/*  before starting.${R}
EOF
}

help_config() {
  cat <<EOF
${B}<project>/.ai/${R}  ${D}(all optional; applied at session start)${R}

  allow       sites the agent may reach, regex per line      ^github\.com\$
  ports       extra outgoing HTTPS ports (443 given)     8443
  publish     ports opened on host 127.0.0.1 at start        3000
  apt         Debian packages baked into the image            postgresql-client
  pip         Python packages, into /opt/venv                 requests
  mask        subdirs hidden inside the sandbox               secrets
  ssh-agent   empty file: agent may sign with your ssh keys   (touch .ai/ssh-agent)

Outside the project:  ~/.local/share/ai/projects/<dir-name>/env   (see: ai help secrets)
EOF
}

help_packages() {
  cat <<EOF
${B}Packages${R}

  echo postgresql-client >> .ai/apt
  echo 'requests==2.32.3' >> .ai/pip
  ai claude .                         ${D}# image ai-<harness>-<dir>:<hash> is built once, then reused${R}

Remove a line to drop a package; the next start builds a new image.
npm / pip / maven installs inside the project also work (those registries are allowed).
EOF
}

help_secrets() {
  cat <<EOF
${B}API keys and tokens${R}

  mkdir -p ~/.local/share/ai/projects/foo
  echo 'STRIPE_KEY=sk_test_...' >> ~/.local/share/ai/projects/foo/env      ${D}# KEY=value per line${R}

They appear as env vars in every session of foo. The file lives outside the project, so the agent
cannot change it. Use test / single-purpose tokens, and allow the API's host too (ai help allow).
EOF
}

help_dev() {
  cat <<EOF
${B}Open the app running in the session${R}

${B}1. Fixed port${R} (server must listen on 0.0.0.0: vite --host, next dev -H 0.0.0.0, uvicorn --host 0.0.0.0)
  echo 3000 >> ~/projects/foo/.ai/publish
  ai claude ~/projects/foo
  browser: http://127.0.0.1:3000

${B}2. Any port, session already running${R} (works for localhost-only servers too)
  ai ports foo
  ai port foo 5173            ${D}# http://127.0.0.1:5173, Ctrl-C stops${R}

From another machine: ai help tailnet
EOF
}

help_api() {
  cat <<EOF
${B}Test an API${R}

  inside the session:   curl http://localhost:8000/health
  from the host:        curl http://127.0.0.1:8000/health      ${D}# after .ai/publish or ai port${R}
  compose service:      curl http://web:8000/health            ${D}# inside the session${R}

The agent calling an outside API: allow the host (ai help allow), put the key in env (ai help secrets).
EOF
}

help_tailnet() {
  cat <<EOF
${B}From the phone / another machine${R}  ${D}(dev ports only listen on 127.0.0.1)${R}

On the host, after .ai/publish or ai port:
  tailscale serve --bg 3000      ${D}# https://<host>.<tailnet>.ts.net -> 127.0.0.1:3000, tailnet only${R}
  tailscale serve status
  tailscale serve reset          ${D}# stop sharing${R}

tailscale funnel = public internet. Not for dev servers.
EOF
}

help_git() {
  cat <<EOF
${B}Git${R}

  commit   inside the session (name/email from your git config, no hooks, no signing)
  push     on the host (github is not allowed and the sandbox has no direct network)
EOF
}

help_errors() {
  cat <<EOF
${B}Common messages${R}

  not below any of: <roots>       AI_ROOT=<parent dir> ai ...
  refusing to mount ...                      that is home, ~/.local/share/ai or a key dir; use a project subdir
  missing ~/.local/share/ai/<h>/home        mkdir -p it, start the session, log in there once
  image not known / --pull=never             ai build
  site unreachable inside                    add it to .ai/allow, restart the session
  no running session for foo                 start one first; foo = project dir name
  several sessions for foo                   close the extra ones
  ai compose: refused ...                    fix the listed lines, then ai compose foo check
  socat missing                              install the socat package

Full compose + network test: tests/compose-test.sh (on the host)
EOF
}

ai_help() {
  local t=${1:-}
  case $t in
    '')                              help_overview ;;
    run|claude|codex|pi|start)       help_run ;;
    shell|bash)                      help_shell ;;
    build|images)                    help_build ;;
    ports)                           help_ports ;;
    port|forward)                    help_port ;;
    compose|db|services)             help_compose ;;
    paths|path|roots|mask)           help_paths ;;
    allow|permissions|perm|network|proxy|block) help_allow ;;
    config|.ai)                      help_config ;;
    packages|apt|pip)                help_packages ;;
    secrets|env|tokens|keys)         help_secrets ;;
    dev|web|publish|browser)         help_dev ;;
    api|test|curl)                   help_api ;;
    tailnet|tailscale|phone|remote)  help_tailnet ;;
    git|push)                        help_git ;;
    errors|error|trouble)            help_errors ;;
    *) echo "ai help: no topic '$t'" >&2; help_overview >&2; return 2 ;;
  esac
}
