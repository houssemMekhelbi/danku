#!/usr/bin/env bash
# End-to-end test for `ai compose`. Run from the host. Creates its own sandbox session (never touches yours),
# a throwaway "bad" project for the guard's refusals, and tears everything down at the end.
set -Eeuo pipefail
here=$(cd "$(dirname "$0")" && pwd)
demo=$here/compose-demo
bad=$here/.tmp-bad-project
pass=0 fail=0
ok()   { echo "  ok   $*"; ((pass++)) || true; }
bad_() { echo "  FAIL $*"; ((fail++)) || true; }
check() { local msg=$1; shift; if "$@" >/dev/null 2>&1; then ok "$msg"; else bad_ "$msg"; fi; }

session=""
cleanup() {
  set +e
  [[ -z $session ]] || podman rm -f "$session" >/dev/null 2>&1
  ai compose "$demo" down -v >/dev/null 2>&1
  rm -rf "$bad"
  # the launcher's own trap removes the session proxy/net once the container is gone
  sleep 2
}
trap cleanup EXIT

echo "== 1. guard refusals"
mkdir -p "$bad/seed"; ln -sfn "$HOME/.ssh" "$bad/link"
cat > "$bad/compose.yaml" <<'EOF'
services:
  a:
    image: docker.io/library/alpine
    privileged: true
    network_mode: host
    build: .
    volumes:
      - ~/X:/hostX
      - ./link:/sneaky
      - /home/agent/seed:/agenthome
      - data:/d
    ports: ["9000"]
volumes:
  data:
    driver_opts: { type: none, device: /etc, o: bind }
EOF
out=$(ai compose "$bad" check 2>&1) && bad_ "bad compose was accepted" || ok "bad compose refused"
for want in "'~/X' is the HOST home" "link (resolves to $HOME/.ssh) is outside" "/home/agent/seed is outside" \
            "'privileged' is refused" "'network_mode: host' is refused" "'build' is refused" \
            "'9000': give an explicit host port" "'driver_opts' is refused"; do
  grep -qF -- "$want" <<<"$out" && ok "reports: $want" || { bad_ "missing: $want"; echo "$out" | sed 's/^/     /'; }
done

echo "== 2. guard rewrites"
cat > "$bad/compose.yaml" <<EOF
services:
  a:
    image: docker.io/library/alpine
    volumes:
      - /workspace/$(basename "$bad")/seed:/seed
    ports: ["0.0.0.0:9000:9000"]
EOF
if ai compose "$bad" check >/dev/null 2>&1; then
  ok "sandbox-absolute path and 0.0.0.0 port accepted"
  st=${XDG_STATE_HOME:-$HOME/.local/state}/ai/compose/$(basename "$bad")/stack.yaml
  check "/workspace/<name> translated to project dir" grep -qF -- "$bad/seed:/seed" "$st"
  check "port rebound to 127.0.0.1"                    grep -qF -- "127.0.0.1:9000:9000" "$st"
  check "network forced internal"                      grep -qE  "internal: true" "$st"
  check "default mem_limit added"                      grep -qE  "mem_limit: 4g" "$st"
else bad_ "rewrite case refused"; ai compose "$bad" check 2>&1 | sed 's/^/     /'; fi

echo "== 3. session first, then stack up (runtime attach)"
before=$(podman ps --format '{{.Names}}' | grep -E '^ai-pi-compose-demo-[0-9]+$' || true)
(cd / && AI_NOTTY=1 ai shell pi "$demo" -c 'sleep 300' >/dev/null 2>&1 &)
for _ in $(seq 30); do
  session=$(comm -13 <(sort <<<"$before") <(podman ps --format '{{.Names}}' | grep -E '^ai-pi-compose-demo-[0-9]+$' | sort) | head -1)
  [[ -n $session ]] && break; sleep 1
done
[[ -n $session ]] || { bad_ "test session did not start"; exit 1; }
ok "test session $session"
check "stack up" ai compose "$demo" up
for _ in $(seq 40); do podman inspect -f '{{.State.Health.Status}}' ai-compose-demo_db_1 2>/dev/null | grep -q healthy && break; sleep 2; done
check "db healthy" sh -c "podman inspect -f '{{.State.Health.Status}}' ai-compose-demo_db_1 | grep -q healthy"
inside() { podman exec "$session" sh -c "$1"; }
check "db resolves by name"            inside 'getent hosts db'
check "tcp to db:5432"                 inside 'nc -z -w 3 db 5432'
check "http to web:8000 serves ./site" sh -c "podman exec $session curl -s -m 5 http://web:8000/ | grep -q 'hello from web'"
check "seed applied (table demo)"      sh -c "podman exec ai-compose-demo_db_1 psql -U postgres -d demo -tAc 'select id from demo' | grep -qx 42"
check "session: api.anthropic.com still via proxy" sh -c "podman exec $session curl -s -m 15 -o /dev/null -w '%{http_code}' https://api.anthropic.com | grep -q 404"
check "session: direct egress still blocked" sh -c "! podman exec $session curl -s -m 5 --noproxy '*' https://example.com"
check "db service: no internet"        sh -c "! podman exec ai-compose-demo_db_1 sh -c 'wget -q -T 5 -O /dev/null https://example.com'"
check "published port on 127.0.0.1 only" sh -c "ss -ltn | grep ':15432 ' | grep -q '127.0.0.1:15432'"
check "ps works"   ai compose "$demo" ps
check "logs works" sh -c "ai compose '$demo' logs db | grep -qi 'database system is ready'"

echo "== 4. down detaches and removes"
check "stack down"             ai compose "$demo" down
check "db no longer resolves"  sh -c "! podman exec $session getent hosts db"
check "stack network removed"  sh -c "! podman network ls --format '{{.Name}}' | grep -q '^ai-compose-demo_'"

echo "== 5. stack first, then new session joins at start"
check "stack up again" ai compose "$demo" up
podman rm -f "$session" >/dev/null 2>&1; session=""; sleep 2
out=$(cd / && AI_NOTTY=1 ai shell pi "$demo" -c 'getent hosts db && nc -z -w 3 db 5432 && echo JOINED' 2>&1 | tail -1)
[[ $out == JOINED ]] && ok "new session reaches db" || bad_ "new session: $out"
out=$(cd / && AI_NOTTY=1 ai shell pi "$demo" -c 'for i in 1 2 3 4 5; do curl -s -m 5 http://web:8000/ && break; sleep 2; done' 2>&1 | tail -1)
[[ $out == "hello from web" ]] && ok "new session: http via proxy to web" || bad_ "new session http: $out"

echo; echo "passed=$pass failed=$fail"; (( fail == 0 ))
