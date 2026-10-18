import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("feed_publication", ROOT / "Scripts/release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


# use a real bare remote so the losing publisher must recover from an actual non-fast-forward push
class FeedPublicationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.remote = self.root / "remote.git"
        self.git("init", "--bare", "--quiet", "--template=", self.remote)
        self.git("--git-dir", self.remote, "symbolic-ref", "HEAD", "refs/heads/updates")
        seed = self.root / "seed"
        self.git("init", "--quiet", "--template=", seed)
        self.git("-C", seed, "checkout", "-q", "-b", "updates")
        self.git("-C", seed, "config", "user.name", "Feed Fixture")
        self.git("-C", seed, "config", "user.email", "fixture@example.com")
        self.git("-C", seed, "config", "commit.gpgsign", "false")
        for channel in ("stable", "beta"):
            path = seed / channel / "appcast.xml"
            release.save_feed(release.empty_feed(channel), path)
            self.sign(path)
        (seed / "README.md").write_text("feed data only\n")
        self.git("-C", seed, "add", ".")
        self.git("-C", seed, "commit", "-q", "-m", "Initial signed feed fixtures")
        self.git("-C", seed, "remote", "add", "origin", self.remote)
        self.git("-C", seed, "push", "-q", "origin", "updates")

    def git(self, *arguments):
        return subprocess.check_output(["git", *map(str, arguments)], stderr=subprocess.PIPE).decode().strip()

    def checkout(self, name):
        path = self.root / name
        self.git("clone", "--quiet", self.remote, path)
        return path

    def plan(self, branch, number):
        plan = release.release_plan(branch, number, 1, "a" * 40, "0.0.1")
        plan.update(signature=base64.b64encode(b"s" * 64).decode(), size=12345)
        return plan

    @staticmethod
    def sign(path):
        # cryptographic signatures are tested by sparkle; this marker detects stale or altered feed bytes
        body = path.read_bytes()
        path.write_bytes(body + b"\n<!--fixture-signature:" + hashlib.sha256(body).hexdigest().encode() + b"-->\n")

    @staticmethod
    def verify(path):
        body, marker = path.read_bytes().rsplit(b"\n<!--fixture-signature:", 1)
        if marker != hashlib.sha256(body).hexdigest().encode() + b"-->\n":
            raise ValueError("the existing feed signature is invalid")

    def remote_bytes(self, channel):
        return subprocess.check_output(["git", "--git-dir", str(self.remote), "show", f"updates:{channel}/appcast.xml"])

    def test_simultaneous_channels_preserve_both_signed_feeds(self):
        barrier = threading.Barrier(2)
        counts = [0, 0]
        plans = [self.plan("main", 1), self.plan("dev", 2)]
        checkouts = [self.checkout("stable"), self.checkout("beta")]

        def publish(index):
            def sign(path):
                self.sign(path)
                counts[index] += 1
                if counts[index] == 1:
                    barrier.wait(timeout=15)
            return release.advance_channel_feed(checkouts[index], plans[index], sign, self.verify)

        with ThreadPoolExecutor(max_workers=2) as workers:
            futures = [workers.submit(publish, index) for index in range(2)]
            for future in futures:
                future.result(timeout=30)
        self.assertGreaterEqual(sum(counts), 3, "one publisher must fetch and sign again after its rejected push")
        for plan in plans:
            data = self.remote_bytes(plan["channel"])
            path = self.root / (plan["channel"] + ".xml")
            path.write_bytes(data)
            self.verify(path)
            feed = ET.fromstring(data)
            self.assertEqual(feed.findtext(f"channel/item/{{{release.SPARKLE}}}version"), plan["build"])
        self.assertEqual(self.git("--git-dir", self.remote, "show", "updates:README.md"), "feed data only")

    def test_later_beta_does_not_block_a_valid_stable_publication(self):
        beta = self.plan("dev", 9)
        release.advance_channel_feed(self.checkout("beta"), beta, self.sign, self.verify)
        untouched_beta = self.remote_bytes("beta")
        stable = self.plan("main", 8)
        release.advance_channel_feed(self.checkout("stable"), stable, self.sign, self.verify)
        self.assertEqual(self.remote_bytes("beta"), untouched_beta)
        self.assertEqual(ET.fromstring(self.remote_bytes("stable")).findtext(f"channel/item/{{{release.SPARKLE}}}version"), stable["build"])

    def test_retry_of_the_same_artifact_is_idempotent_and_conflicting_metadata_fails(self):
        plan = self.plan("main", 3)
        checkout = self.checkout("publisher")
        first = release.advance_channel_feed(checkout, plan, self.sign, self.verify)
        second = release.advance_channel_feed(checkout, plan, self.sign, self.verify)
        self.assertEqual(first, second)
        altered = dict(plan, signature=base64.b64encode(b"x" * 64).decode())
        with self.assertRaisesRegex(ValueError, "different update metadata"):
            release.advance_channel_feed(checkout, altered, self.sign, self.verify)
        with self.assertRaisesRegex(ValueError, "stale"):
            release.advance_channel_feed(checkout, self.plan("main", 2), self.sign, self.verify)
        self.assertEqual(self.git("--git-dir", self.remote, "rev-parse", "updates"), first)

    def test_an_altered_remote_feed_is_not_resigned(self):
        checkout = self.checkout("altered")
        path = checkout / "stable/appcast.xml"
        path.write_bytes(path.read_bytes().replace(b"<title>Fileel</title>", b"<title>Altered</title>"))
        self.git("-C", checkout, "config", "user.name", "Feed Fixture")
        self.git("-C", checkout, "config", "user.email", "fixture@example.com")
        self.git("-C", checkout, "config", "commit.gpgsign", "false")
        self.git("-C", checkout, "commit", "-qam", "Alter feed without its signature")
        self.git("-C", checkout, "push", "-q", "origin", "updates")
        before = self.git("--git-dir", self.remote, "rev-parse", "updates")
        signed = []
        with self.assertRaisesRegex(ValueError, "signature is invalid"):
            release.advance_channel_feed(checkout, self.plan("main", 4), lambda path: signed.append(path), self.verify)
        self.assertFalse(signed)
        self.assertEqual(self.git("--git-dir", self.remote, "rev-parse", "updates"), before)

    def test_feed_publication_cannot_target_source_branches(self):
        checkout = self.checkout("guard")
        for branch in ("main", "dev", "../main", "ci-feed-verification-invalid"):
            with self.assertRaisesRegex(ValueError, "application branch"):
                release.advance_channel_feed(checkout, self.plan("main", 1), self.sign, self.verify, branch=branch)


if __name__ == "__main__":
    unittest.main()
