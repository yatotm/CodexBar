"""使用合成数据验证首次迁移, 不访问真实偏好或账户"""

import importlib.util
from pathlib import Path
import sqlite3
import plistlib
from types import SimpleNamespace
from unittest.mock import patch
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("fork_migration", Path(__file__).resolve().parents[1] / "Scripts/migrate-fork.py")
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class MigrationTests(unittest.TestCase):
    def test_preserves_preferences_but_requires_new_authorization(self):
        source = {"AutoReset.enabled": True, "KeepAlive.isEnabled": True,
                  "WorkflowSync.isEnabled": True, "WorkflowSync.cursor": "old",
                  "SUFeedURL": "old", "SUEnableAutomaticChecks": False, "UsageAnalytics.quotaReference.hash": "pro5x",
                  "CodexProxy.configuration": b"fixture"}
        result = migration.migrated_preferences(source)
        self.assertTrue(source["AutoReset.enabled"])
        self.assertFalse(result["AutoReset.enabled"])
        self.assertFalse(result["KeepAlive.isEnabled"])
        self.assertFalse(result["WorkflowSync.isEnabled"])
        self.assertNotIn("WorkflowSync.cursor", result)
        self.assertNotIn("SUFeedURL", result)
        self.assertIs(result["SUEnableAutomaticChecks"], False)
        self.assertEqual(result["CodexProxy.configuration"], b"fixture")
        self.assertEqual(result["UsageAnalytics.quotaReference.hash"], "pro5x")

    def test_empty_defaults_export_does_not_block_first_migration(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(migration, "read_preferences", return_value={"theme": "dark"}), patch.object(migration.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout=plistlib.dumps({}))), patch("builtins.print"):
            migration.migrate(Path(directory), "debug", "release")
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_existing_preferences_are_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(migration, "read_preferences", return_value={"theme": "dark"}), patch.object(migration.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout=plistlib.dumps({"theme": "light"}))):
            with self.assertRaisesRegex(RuntimeError, "避免覆盖"):
                migration.migrate(Path(directory), "debug", "release", apply=True)

    def test_missing_source_preferences_are_reported(self):
        with patch.object(migration.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout=plistlib.dumps({}))):
            with self.assertRaisesRegex(RuntimeError, "为空"):
                migration.read_preferences("fixture")

    def test_copies_sqlite_wal_and_skips_cloud_cache_and_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, target = root / "old", root / "new"
            source.mkdir()
            (source / "Sync").mkdir()
            (source / "Sync/cursor.json").write_text("old")
            (source / "events.jsonl").write_text("{}\n")
            (source / "stats.lock").touch()
            (source / "outside").symlink_to(root)
            with sqlite3.connect(source / "center-v1.sqlite") as db:
                db.execute("PRAGMA journal_mode=WAL")
                db.execute("CREATE TABLE observations (value INTEGER)")
                db.execute("INSERT INTO observations VALUES (7)")
                db.commit()
                migration.copy_data(source, target)
            with sqlite3.connect(target / "center-v1.sqlite") as db:
                self.assertEqual(db.execute("SELECT value FROM observations").fetchone(), (7,))
            self.assertFalse((target / "Sync").exists())
            self.assertFalse((target / "stats.lock").exists())
            self.assertFalse((target / "outside").exists())
            self.assertTrue((source / "Sync/cursor.json").exists())
            self.assertEqual((target / "events.jsonl").read_text(), "{}\n")


if __name__ == "__main__":
    unittest.main()
