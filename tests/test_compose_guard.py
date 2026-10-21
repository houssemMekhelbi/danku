"""Unit tests for compose-guard.py. No podman needed: python3 -m unittest discover -s tests"""
import importlib.util
import os
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("compose_guard", ROOT / "compose-guard.py")
cg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cg)


class GuardTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.project = os.path.realpath(os.path.join(self.tmp.name, "demo"))
        os.makedirs(os.path.join(self.project, "data"))
        self.guard = cg.Guard(self.project, "demo")

    def tearDown(self):
        self.tmp.cleanup()

    def run_guard(self, doc):
        out = self.guard.run(doc)
        return out, "\n".join(self.guard.errors)

    def svc(self, **keys):
        return {"services": {"a": {"image": "alpine", **keys}}}

    # --- refusals ------------------------------------------------------------------------------
    def test_refuses_privilege_keys(self):
        for key, value in [("privileged", True), ("cap_add", ["SYS_ADMIN"]), ("devices", ["/dev/kvm"]),
                           ("security_opt", ["seccomp=unconfined"]), ("build", "."), ("volumes_from", ["b"])]:
            with self.subTest(key=key):
                self.guard = cg.Guard(self.project, "demo")
                _, errors = self.run_guard(self.svc(**{key: value}))
                self.assertIn(f"'{key}' is refused", errors)

    def test_refuses_host_namespaces(self):
        _, errors = self.run_guard(self.svc(network_mode="host", pid="host"))
        self.assertIn("'network_mode: host' is refused", errors)
        self.assertIn("'pid: host' is refused", errors)

    def test_refuses_host_home(self):
        _, errors = self.run_guard(self.svc(volumes=["~/.ssh:/keys"]))
        self.assertIn("is the HOST home directory", errors)

    def test_refuses_paths_outside_project(self):
        _, errors = self.run_guard(self.svc(volumes=["/etc:/host-etc", "../:/parent"]))
        self.assertEqual(errors.count("is outside the project"), 2)

    def test_refuses_symlink_escape(self):
        os.symlink("/etc", os.path.join(self.project, "link"))
        _, errors = self.run_guard(self.svc(volumes=["./link:/x"]))
        self.assertIn("resolves to /etc", errors)

    def test_refuses_bind_mount_in_disguise(self):
        doc = self.svc(volumes=["data:/d"])
        doc["volumes"] = {"data": {"driver_opts": {"type": "none", "device": "/etc", "o": "bind"}}}
        _, errors = self.run_guard(doc)
        self.assertIn("'driver_opts' is refused", errors)

    def test_refuses_external_resources(self):
        doc = self.svc()
        doc["networks"] = {"outside": {"external": True}}
        doc["volumes"] = {"v": {"external": True}}
        _, errors = self.run_guard(doc)
        self.assertIn("networks.outside: 'external' is refused", errors)
        self.assertIn("volumes.v: 'external' is refused", errors)

    def test_refuses_random_host_port(self):
        _, errors = self.run_guard(self.svc(ports=["9000"]))
        self.assertIn("give an explicit host port", errors)

    def test_refuses_undeclared_named_volume(self):
        _, errors = self.run_guard(self.svc(volumes=["ghost:/g"]))
        self.assertIn("named volume 'ghost' is not declared", errors)

    # --- rewrites ------------------------------------------------------------------------------
    def test_ports_rebound_to_loopback(self):
        out, errors = self.run_guard(self.svc(ports=["0.0.0.0:8080:80", "5432:5432/tcp", {"published": 9000, "target": 90}]))
        self.assertEqual(errors, "")
        self.assertEqual(out["services"]["a"]["ports"][:2], ["127.0.0.1:8080:80", "127.0.0.1:5432:5432/tcp"])
        self.assertEqual(out["services"]["a"]["ports"][2]["host_ip"], "127.0.0.1")

    def test_sandbox_path_translated_to_project(self):
        out, errors = self.run_guard(self.svc(volumes=["/workspace/demo/data:/data", "./data:/data2:ro"]))
        self.assertEqual(errors, "")
        self.assertEqual(out["services"]["a"]["volumes"],
                         [f"{self.project}/data:/data", f"{self.project}/data:/data2:ro"])

    def test_networks_forced_internal(self):
        doc = self.svc()
        doc["networks"] = {"front": {}}
        out, errors = self.run_guard(doc)
        self.assertEqual(errors, "")
        self.assertTrue(out["networks"]["front"]["internal"])

    def test_default_network_added_internal(self):
        out, _ = self.run_guard(self.svc())
        self.assertEqual(out["networks"], {"default": {"internal": True}})

    def test_default_limits_added_lower_kept(self):
        out, _ = self.run_guard({"services": {"a": {"image": "alpine"}, "b": {"image": "alpine", "mem_limit": "256m"}}})
        self.assertEqual(out["services"]["a"]["mem_limit"], cg.DEFAULT_MEM)
        self.assertEqual(out["services"]["a"]["pids_limit"], cg.DEFAULT_PIDS)
        self.assertEqual(out["services"]["b"]["mem_limit"], "256m")

    def test_clean_stack_passes(self):
        doc = {"services": {"db": {"image": "postgres:16-alpine", "volumes": ["pg:/var/lib/postgresql/data", "./data:/seed:ro"],
                                   "ports": ["127.0.0.1:15432:5432"]}},
               "volumes": {"pg": {}}}
        _, errors = self.run_guard(doc)
        self.assertEqual(errors, "")


if __name__ == "__main__":
    unittest.main()
