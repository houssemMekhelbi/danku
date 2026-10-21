#!/usr/bin/python3 -I
"""compose-guard: fence an agent-written compose file to its project.

usage: compose-guard.py <project-dir> <project-name> <resolved-config.yaml>  > rewritten.yaml

Input is the output of `podman-compose config` (variables interpolated, extends merged). The compose file is
written by the sandboxed agent and interpreted by podman on the HOST, so every path in it is a host path.
Rules:
  * every host path (bind sources, env_file, configs/secrets file, build context) must realpath() to inside
    the project; /workspace/<name>/... is translated to the project dir first (the agent's view of it)
  * refused: privileged, cap_add, devices, network_mode host|container:*, pid/ipc/uts host, security_opt,
    userns_mode, volumes_from, build, cgroup_parent, external volumes/networks, volume driver/driver_opts
  * ports are rewritten to bind 127.0.0.1; a bare container port (random host port) is refused
  * all networks are forced internal; a default network is added if none is declared
  * default limits: mem_limit 4g, pids_limit 1024 (kept if the file sets lower ones)
Exit 1 with one line per violation on stderr; nothing is run unless this exits 0.
"""
import os
import sys

import yaml

REFUSED_SERVICE_KEYS = (
    "privileged", "cap_add", "devices", "security_opt", "userns_mode", "volumes_from",
    "build", "cgroup_parent", "device_cgroup_rules", "sysctls", "extends", "external_links",
)
HOST_NS_KEYS = ("pid", "ipc", "uts", "cgroup")
DEFAULT_MEM = "4g"
DEFAULT_PIDS = 1024


class Guard:
    def __init__(self, project: str, name: str):
        self.project = os.path.realpath(project)
        self.name = name
        self.errors: list[str] = []

    def err(self, where: str, msg: str) -> None:
        self.errors.append(f"{where}: {msg}")

    # --- paths ---------------------------------------------------------------------------------------
    def host_path(self, where: str, p: str) -> str | None:
        """Return the host path for p if it is inside the project, else record an error."""
        if not isinstance(p, str) or not p:
            self.err(where, "empty path")
            return None
        ws = f"/workspace/{self.name}"
        if p == ws or p.startswith(ws + "/"):
            p = self.project + p[len(ws):]
        elif p == "~" or p.startswith("~/"):
            self.err(where, f"'{p}' is the HOST home directory, not the sandbox one. "
                            "Only files inside the project can be mounted; copy them into the project and use ./path")
            return None
        elif not p.startswith("/"):
            p = os.path.join(self.project, p)
        real = os.path.realpath(p)
        if real != self.project and not real.startswith(self.project + "/"):
            via = f" (resolves to {real})" if real != p else ""
            self.err(where, f"path {p}{via} is outside the project. "
                            "Only files inside the project can be mounted; use a relative path like ./data")
            return None
        return real

    # --- volumes -------------------------------------------------------------------------------------
    def volume(self, svc: str, v, named: set[str]):
        where = f"services.{svc}.volumes"
        if isinstance(v, str):
            parts = v.split(":")
            if len(parts) == 1:  # anonymous volume
                return v
            src, rest = parts[0], parts[1:]
            if src.startswith(("/", ".", "~")):
                real = self.host_path(where, src)
                if real is None:
                    return v
                return ":".join([real, *rest])
            if src not in named:
                self.err(where, f"named volume '{src}' is not declared under top-level volumes")
            return v
        if isinstance(v, dict):
            t = v.get("type", "volume")
            if t == "bind":
                real = self.host_path(where, v.get("source", ""))
                if real is not None:
                    v = {**v, "source": real}
            elif t == "volume":
                if v.get("source") and v["source"] not in named:
                    self.err(where, f"named volume '{v['source']}' is not declared under top-level volumes")
            elif t == "tmpfs":
                pass
            else:
                self.err(where, f"volume type '{t}' is refused")
            return v
        self.err(where, f"unrecognised volume entry {v!r}")
        return v

    # --- ports ---------------------------------------------------------------------------------------
    def port(self, svc: str, p):
        where = f"services.{svc}.ports"
        if isinstance(p, int):
            p = str(p)
        if isinstance(p, str):
            proto = ""
            if "/" in p:
                p, proto = p.split("/", 1)
                proto = "/" + proto
            parts = p.split(":")
            if len(parts) == 1:
                self.err(where, f"'{p}': give an explicit host port, e.g. 127.0.0.1:{p}:{p}")
                return p
            if len(parts) == 2:
                host, cont = parts
            elif len(parts) == 3:
                _, host, cont = parts  # host ip is replaced
            else:
                self.err(where, f"'{p}': cannot parse")
                return p
            if not host:
                self.err(where, f"'{p}': give an explicit host port")
                return p
            return f"127.0.0.1:{host}:{cont}{proto}"
        if isinstance(p, dict):
            if not p.get("published"):
                self.err(where, "long syntax without 'published': give an explicit host port")
                return p
            return {**p, "host_ip": "127.0.0.1"}
        self.err(where, f"unrecognised port entry {p!r}")
        return p

    # --- services ------------------------------------------------------------------------------------
    def service(self, svc: str, s: dict, named: set[str], nets: set[str]) -> dict:
        where = f"services.{svc}"
        if not isinstance(s, dict):
            self.err(where, "not a mapping")
            return s
        for k in REFUSED_SERVICE_KEYS:
            if k in s:
                self.err(where, f"'{k}' is refused in the sandbox stack")
        for k in HOST_NS_KEYS:
            if k in s and (s[k] == "host" or str(s[k]).startswith(("container:", "service:"))):
                self.err(where, f"'{k}: {s[k]}' is refused")
        nm = s.get("network_mode")
        if nm is not None and (nm == "host" or str(nm).startswith(("container:", "service:"))):
            self.err(where, f"'network_mode: {nm}' is refused")
        if "volumes" in s:
            s["volumes"] = [self.volume(svc, v, named) for v in s["volumes"]]
        if "ports" in s:
            s["ports"] = [self.port(svc, p) for p in s["ports"]]
        for key in ("env_file",):
            if key in s:
                items = s[key] if isinstance(s[key], list) else [s[key]]
                out = []
                for it in items:
                    if isinstance(it, dict):
                        real = self.host_path(f"{where}.{key}", it.get("path", ""))
                        out.append({**it, "path": real} if real else it)
                    else:
                        real = self.host_path(f"{where}.{key}", it)
                        out.append(real or it)
                s[key] = out
        for key in ("configs", "secrets"):
            for it in s.get(key, []) or []:
                src = it.get("source") if isinstance(it, dict) else it
                if src not in nets_or(self.top.get(key)):
                    self.err(f"{where}.{key}", f"'{src}' is not declared at top level")
        if "networks" in s:
            lst = s["networks"] if isinstance(s["networks"], list) else list(s["networks"].keys())
            for n in lst:
                if n not in nets:
                    self.err(f"{where}.networks", f"'{n}' is not declared under top-level networks")
        # limits
        s.setdefault("mem_limit", DEFAULT_MEM)
        s.setdefault("pids_limit", DEFAULT_PIDS)
        return s

    # --- top level -----------------------------------------------------------------------------------
    def run(self, doc: dict) -> dict:
        self.top = doc
        if not isinstance(doc, dict) or not isinstance(doc.get("services"), dict):
            self.err("compose", "no services mapping")
            return doc
        for key in ("include",):
            if key in doc:
                self.err("compose", f"'{key}' is refused")
        vols = doc.get("volumes") or {}
        for n, v in vols.items():
            v = v or {}
            if v.get("external"):
                self.err(f"volumes.{n}", "'external' is refused")
            for k in ("driver", "driver_opts"):
                if k in v:
                    self.err(f"volumes.{n}", f"'{k}' is refused (bind mounts in disguise)")
        nets = doc.get("networks") or {}
        if not nets:
            nets = {"default": {}}
        for n, v in list(nets.items()):
            v = dict(v or {})
            if v.get("external"):
                self.err(f"networks.{n}", "'external' is refused")
            if v.get("driver") not in (None, "bridge"):
                self.err(f"networks.{n}", f"driver '{v['driver']}' is refused")
            v["internal"] = True
            nets[n] = v
        doc["networks"] = nets
        for key in ("configs", "secrets"):
            for n, c in (doc.get(key) or {}).items():
                c = c or {}
                if c.get("external"):
                    self.err(f"{key}.{n}", "'external' is refused")
                if "file" in c:
                    real = self.host_path(f"{key}.{n}.file", c["file"])
                    if real:
                        c["file"] = real
                doc[key][n] = c
        for svc, s in doc["services"].items():
            doc["services"][svc] = self.service(svc, s, set(vols.keys()), set(nets.keys()))
        return doc


def nets_or(m):
    return set((m or {}).keys())


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    project, name, cfg = sys.argv[1:]
    with open(cfg) as f:
        doc = yaml.safe_load(f)
    g = Guard(project, name)
    out = g.run(doc)
    if g.errors:
        print("danku compose: refused, fix the compose file:", file=sys.stderr)
        for e in g.errors:
            print("  " + e, file=sys.stderr)
        return 1
    yaml.safe_dump(out, sys.stdout, sort_keys=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
