import base64
import importlib.util
import copy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET


# exercise publication contracts without credentials or network access
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("fileel_release", ROOT / "Scripts/release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def plan(self, branch="main", run=1, attempt=1):
        return release.release_plan(branch, run, attempt, "a" * 40, "0.0.1")

    def test_publication_refuses_to_run_before_acceptance(self):
        with patch.dict(release.os.environ, {}, clear=True):
            with self.assertRaisesRegex(ValueError, "acceptance is still locked"):
                release.publish_release()

    def test_rehearsal_tags_cannot_target_normal_release_tags(self):
        self.assertEqual(release.rehearsal_tag("1234", "2"), "ci-verification-1234-2")
        self.assertFalse(release.rehearsal_tag("1234", "2").startswith("v"))
        for run, attempt in [("v1.0", "1"), ("1234", "--force"), ("0", "1"), ("1234\n", "1")]:
            with self.assertRaises(ValueError):
                release.rehearsal_tag(run, attempt)

    def test_rehearsal_never_deletes_an_existing_draft_when_creation_fails(self):
        plan = self.plan("dev")
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            (directory / "plan.json").write_text(release.json.dumps(plan))
            public = directory / "public"; public.mkdir()
            for name in (plan["filename"], plan["filename"] + ".sha256", "release.json", "Fileel-Runtime-Sources.tar", "Fileel-Runtime-Sources.tar.sha256"):
                (public / name).write_bytes(b"fixture")
            environment = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REPOSITORY": release.REPOSITORY,
                           "GITHUB_SHA": plan["sha"], "GITHUB_RUN_ID": "1234", "GITHUB_RUN_ATTEMPT": "1"}
            with patch.dict(release.os.environ, environment), patch.object(release, "workspace", return_value=directory), \
                    patch.object(release, "gh_json", return_value=[]), \
                    patch.object(release, "run", side_effect=RuntimeError("draft already exists")) as run:
                with self.assertRaises(RuntimeError):
                    release.rehearse_release()
                self.assertEqual(run.call_count, 1)
                self.assertEqual(run.call_args.args[0][:3], ["gh", "release", "create"])

    def test_untrusted_branches_and_invalid_versions_cannot_publish(self):
        for branch in ["feature/example", "updates", "refs/pull/1/merge", "main\nmalicious"]:
            with self.assertRaises(ValueError):
                self.plan(branch)
        with self.assertRaises(ValueError):
            release.release_plan("main", 1, 1, "short", "0.0.1")
        with self.assertRaises(ValueError):
            release.release_plan("main", 1, 1, "a" * 40, "0.0.1;echo unsafe")
        for run, attempt in [(0, 1), (1, 0), (1, 100)]:
            with self.assertRaises(ValueError):
                self.plan(run=run, attempt=attempt)

    def test_channels_share_a_monotonic_build_sequence(self):
        stable = self.plan()
        beta = self.plan("dev", 2)
        next_stable = self.plan("main", 3)
        self.assertLess(release.build_tuple(stable["build"]), release.build_tuple(beta["build"]))
        self.assertLess(release.build_tuple(beta["build"]), release.build_tuple(next_stable["build"]))
        self.assertLess(release.build_tuple(beta["build"]), release.build_tuple(self.plan("dev", 2, 2)["build"]))
        self.assertEqual(stable["channel"], "stable")
        self.assertEqual(beta["channel"], "beta")
        self.assertTrue(beta["tag"].endswith("-beta"))
        self.assertIn("-stable-arm64.dmg", stable["filename"])
        self.assertIn("-beta-arm64.dmg", beta["filename"])

    def test_feed_routes_only_to_verified_versioned_assets(self):
        signature = base64.b64encode(b"s" * 64).decode()
        for branch in ["main", "dev"]:
            plan = self.plan(branch)
            root = release.empty_feed(plan["channel"])
            release.append_release(root, plan, signature, 12345)
            item = root.find("channel/item")
            enclosure = item.find("enclosure")
            self.assertEqual(enclosure.get("length"), "12345")
            self.assertEqual(enclosure.get(f"{{{release.SPARKLE}}}edSignature"), signature)
            self.assertEqual(enclosure.get("url"), f"https://github.com/thiagonarcizo/Fileel/releases/download/{plan['tag']}/{plan['filename']}")
            self.assertEqual(item.findtext(f"{{{release.SPARKLE}}}channel"), "beta" if branch == "dev" else None)
            with tempfile.TemporaryDirectory() as temp:
                path = Path(temp) / "appcast.xml"
                release.save_feed(root, path)
                restored = release.read_feed(path, plan["channel"])
                self.assertEqual(restored.findtext(f"channel/item/{{{release.SPARKLE}}}version"), plan["build"])

    def test_stale_updates_and_missing_signatures_are_rejected(self):
        root = release.empty_feed("stable")
        signature = base64.b64encode(b"s" * 64).decode()
        release.append_release(root, self.plan(run=3), signature, 200)
        before = ET.tostring(root)
        for run in [1, 3]:
            with self.assertRaises(ValueError):
                release.append_release(root, self.plan(run=run), signature, 100)
            self.assertEqual(ET.tostring(root), before)
        for invalid in ["", "not base64", base64.b64encode(b"short").decode()]:
            with self.assertRaises(ValueError):
                release.append_release(root, self.plan(run=4), invalid, 100)
        with self.assertRaises(ValueError):
            release.append_release(root, self.plan(run=4), signature, 0)

    def test_history_is_bounded_and_other_channel_is_unchanged(self):
        stable = release.empty_feed("stable")
        beta = release.empty_feed("beta")
        original_beta = ET.tostring(beta)
        signature = base64.b64encode(b"s" * 64).decode()
        for run in range(1, 13):
            release.append_release(stable, self.plan(run=run), signature, 100)
        self.assertEqual(len(stable.findall("channel/item")), 10)
        self.assertEqual(stable.findtext(f"channel/item/{{{release.SPARKLE}}}version"), "112.1")
        self.assertEqual(ET.tostring(beta), original_beta)

    def test_built_bundle_must_include_real_typed_update_policies(self):
        plan = self.plan()
        info = {
            "FileelUpdateBranch": "main", "SUPublicEDKey": release.PUBLIC_KEY,
            "SUFeedURL": "https://raw.githubusercontent.com/thiagonarcizo/Fileel/updates/stable/appcast.xml",
            "CFBundleIdentifier": "xyz.narcizo.Fileel", "CFBundleVersion": plan["build"],
            "CFBundleShortVersionString": plan["marketing"], "SUScheduledCheckInterval": 3600,
            "LSUIElement": True, "SUEnableAutomaticChecks": True, "SUEnableInstallerLauncherService": True,
            "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True,
        }
        release.verify_app_info(info, plan)
        for key in info:
            broken = copy.deepcopy(info); del broken[key]
            with self.assertRaises(ValueError, msg=key):
                release.verify_app_info(broken, plan)
        broken = copy.deepcopy(info); broken["SURequireSignedFeed"] = "YES"
        with self.assertRaises(ValueError):
            release.verify_app_info(broken, plan)
        beta = self.plan("dev")
        with self.assertRaises(ValueError):
            release.verify_app_info(info, beta)
        info["FileelUpdateBranch"] = "dev"
        info["SUFeedURL"] = info["SUFeedURL"].replace("/stable/", "/beta/")
        release.verify_app_info(info, beta)


if __name__ == "__main__":
    unittest.main()
