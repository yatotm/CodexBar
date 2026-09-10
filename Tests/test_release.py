"""验证发布边界, 不访问 GitHub 或读取维护者凭据"""

import hashlib
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("publish_release", Path(__file__).resolve().parents[1] / "Scripts/publish-release.py")
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)
package_spec = importlib.util.spec_from_file_location("package_release", Path(__file__).resolve().parents[1] / "Scripts/package-release.py")
packager = importlib.util.module_from_spec(package_spec)
package_spec.loader.exec_module(packager)
COMMIT = "a" * 40


class PackageSigningTests(unittest.TestCase):
    def test_matching_team_enables_power_in_install_notes(self):
        with patch.object(packager, "signing_team", side_effect=["TEAM", "TEAM"]):
            self.assertTrue(packager.supports_power_service(Path("CodexBar.app")))

    def test_ad_hoc_package_keeps_power_unavailable(self):
        with patch.object(packager, "signing_team", side_effect=[None, None]):
            self.assertFalse(packager.supports_power_service(Path("CodexBar.app")))

    def test_mismatched_helper_signer_is_rejected(self):
        with patch.object(packager, "signing_team", side_effect=["TEAM", "OTHER"]):
            with self.assertRaisesRegex(ValueError, "签名身份不一致"):
                packager.supports_power_service(Path("CodexBar.app"))


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.previous = Path.cwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, self.previous)
        self.addCleanup(self.temp.cleanup)
        (self.root / "Config").mkdir()
        (self.root / "Config/Version.xcconfig").write_text("MARKETING_VERSION = 1.0.0\nCURRENT_PROJECT_VERSION = 1\n")
        (self.root / "ReleaseNotes").mkdir()
        (self.root / "ReleaseNotes/fork-v1.0.0.md").write_text("测试说明")
        self.output = self.root / "output"
        self.output.mkdir()
        for suffix in ("zip", "dmg"):
            (self.output / f"CodexBar-fork-v1.0.0.{suffix}").write_bytes(b"fixture")
        (self.output / "appcast.xml").write_text('''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <sparkle:version>1</sparkle:version><sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
        <enclosure url="https://github.com/yatotm/CodexBar/releases/download/fork-v1.0.0/CodexBar-fork-v1.0.0.zip" length="7"/>
        </item></channel></rss>''')
        self.names = ["CodexBar-fork-v1.0.0.zip", "CodexBar-fork-v1.0.0.dmg", "appcast.xml", "SHA256SUMS.txt"]
        self.checksums()
        self.env = patch.dict(os.environ, {"GITHUB_REPOSITORY": "yatotm/CodexBar"})
        self.env.start()
        self.addCleanup(self.env.stop)

    def checksums(self):
        (self.output / "SHA256SUMS.txt").write_text("".join(
            f"{hashlib.sha256((self.output / name).read_bytes()).hexdigest()}  {name}\n" for name in self.names[:3]))

    def publish(self):
        publisher.publish(self.output, "fork-v1.0.0", COMMIT)

    def test_mismatched_artifact_fails_before_network(self):
        (self.output / self.names[1]).write_bytes(b"changed")
        with patch.object(publisher, "api") as api:
            with self.assertRaisesRegex(ValueError, "校验失败"):
                self.publish()
            api.assert_not_called()

    def test_wrong_feed_version_fails_before_network(self):
        feed = self.output / "appcast.xml"
        feed.write_text(feed.read_text().replace(">1<", ">0<"))
        self.checksums()
        with patch.object(publisher, "api") as api:
            with self.assertRaisesRegex(ValueError, "版本配置不一致"):
                self.publish()
            api.assert_not_called()

    def test_refuses_existing_tag_on_other_commit(self):
        with patch.object(publisher, "api", side_effect=[None, {"object": {"type": "commit", "sha": "b" * 40}}]) as api:
            with self.assertRaisesRegex(ValueError, "不允许覆盖"):
                self.publish()
            self.assertEqual(api.call_count, 2)

    def test_refuses_older_release(self):
        with patch.object(publisher, "api", return_value={"tag_name": "fork-v1.1.0"}) as api:
            with self.assertRaisesRegex(ValueError, "较旧版本"):
                self.publish()
            self.assertEqual(api.call_count, 1)

    def test_complete_published_release_is_immutable(self):
        responses = [None, {"object": {"type": "tag", "sha": "c" * 40}},
                     {"object": {"type": "commit", "sha": COMMIT}},
                     {"draft": False, "assets": [{"name": name} for name in self.names]}]
        with patch.object(publisher, "api", side_effect=responses), patch.object(publisher.subprocess, "run") as run:
            self.publish()
            run.assert_not_called()

    def test_upload_failure_leaves_draft_unpublished(self):
        responses = [None, None, {"sha": "c" * 40}, {}, None, {"id": 123}]
        with patch.object(publisher, "api", side_effect=responses) as api, patch.object(publisher.subprocess, "run", side_effect=RuntimeError("upload failed")):
            with self.assertRaisesRegex(RuntimeError, "upload failed"):
                self.publish()
            self.assertEqual(api.call_args.args[0], "releases")
            self.assertTrue(api.call_args.args[1]["draft"])

    def test_success_creates_annotated_tag_then_publishes(self):
        responses = [None, None, {"sha": "c" * 40}, {}, None, {"id": 123}, {}]
        with patch.object(publisher, "api", side_effect=responses) as api, patch.object(publisher.subprocess, "run") as run:
            self.publish()
            self.assertEqual(api.call_args_list[2].args[0], "git/tags")
            self.assertEqual(api.call_args_list[2].args[1]["object"], COMMIT)
            self.assertEqual(api.call_args_list[3].args[1]["sha"], "c" * 40)
            self.assertFalse(api.call_args.args[1]["draft"])
            run.assert_called_once()


if __name__ == "__main__":
    unittest.main()
