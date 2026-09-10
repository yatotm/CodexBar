import importlib.util
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("usage_timer", ROOT / "Collector/install-timer.py")
timer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(timer)


class TimerTests(unittest.TestCase):
    def test_units_run_fixed_collector_without_network_or_payload_logging(self):
        config = {"user": "example", "home": "/home/example", "stateDirectory": "/home/example/state",
                  "codexHome": "/home/example/.codex", "claudeHome": "/home/example/.claude",
                  "script": "/home/example/share/collector.py", "providers": "codex,claude"}
        units = timer.units(config)
        service = units[timer.SERVICE]
        self.assertIn('"--quiet"', service)
        self.assertIn('"--state-dir" "/home/example/state"', service)
        self.assertIn("PrivateNetwork=yes", service)
        self.assertIn("ProtectSystem=strict", service)
        self.assertIn("StandardOutput=null", service)
        self.assertIn("Type=oneshot", service)
        self.assertIn("OnCalendar=*:0/5", units[timer.TIMER])
        self.assertIn("Persistent=true", units[timer.TIMER])

    def test_unit_arguments_escape_specifiers_and_shell_variables(self):
        self.assertEqual(timer.quote('/home/a b/%name/$key', command=True), '"/home/a b/%%name/$$key"')
        self.assertEqual(timer.quote('/home/$key'), '"/home/$key"')
        with self.assertRaises(ValueError):
            timer.quote("/tmp/value\nExecStart=anything")

    def test_installation_does_not_overwrite_unmanaged_unit_or_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            unit = root / timer.SERVICE
            unit.write_text("unrelated service")
            with self.assertRaises(ValueError):
                timer.ensure_managed([unit])
            unit.write_text(timer.MARKER + "[Service]\n")
            timer.ensure_managed([unit])
            link = root / "link.service"
            link.symlink_to(unit)
            with self.assertRaises(ValueError):
                timer.ensure_managed([link])


if __name__ == "__main__":
    unittest.main()
