#!/usr/bin/env python3
"""exercise real signed downloads, installation, relaunch and channel changes in an isolated app"""

import argparse
import functools
import http.server
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import threading
import time
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
NAMESPACE = "xyz.narcizo.Fileel.UpdateSmoke"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
spec = importlib.util.spec_from_file_location("fileel_release", ROOT / "Scripts/release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class UpdateProof:
    def __init__(self, options):
        self.options = options
        self.root = options.directory.resolve()
        self.root.mkdir(mode=0o700, parents=True, exist_ok=False)
        self.server_root = self.root / "server"
        self.artifacts = self.server_root / "artifacts"
        self.artifacts.mkdir(parents=True)
        self.tools = options.sparkle / "bin"
        self.framework = options.sparkle / "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
        self.installed = self.root / "Installed/Fileel.app"
        self.signatures = {}
        self.address = ""
        # the fixture and http server never inherit signing credentials from the parent job
        self.child_env = {key: os.environ[key] for key in ("HOME", "TMPDIR", "USER", "LOGNAME", "DEVELOPER_DIR") if key in os.environ}
        self.child_env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"

    def run(self, arguments, **options):
        result = subprocess.run(list(map(str, arguments)), **options)
        if result.returncode:
            raise RuntimeError(f"update proof: {Path(arguments[0]).name} failed ({result.returncode})")
        return result

    def build_candidates(self):
        executable = self.root / "UpdateSmokeHost"
        self.run(["swiftc", "-parse-as-library", "-target", "arm64-apple-macosx14.0", "-F", self.framework.parent,
                  "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                  ROOT / "Scripts/UpdateSmokeHost.swift", ROOT / "Fileel/UpdateChannel.swift", "-o", executable])
        for version in (90, 91, 92, 93):
            app = self.root / "Candidates" / str(version) / "Fileel.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            shutil.copy2(executable, app / "Contents/MacOS/UpdateSmokeHost")
            self.run(["ditto", self.framework, app / "Contents/Frameworks/Sparkle.framework"])
            info = {
                "CFBundleIdentifier": NAMESPACE, "CFBundleName": "Fileel Update Smoke", "CFBundlePackageType": "APPL",
                "CFBundleExecutable": "UpdateSmokeHost", "CFBundleVersion": str(version), "CFBundleShortVersionString": "0.0.1",
                "LSUIElement": True, "LSMinimumSystemVersion": "14.0", "FileelUpdateBranch": "dev" if version == 92 else "main",
                "SUFeedURL": "http://127.0.0.1:8771/stable/appcast.xml", "SUPublicEDKey": release.PUBLIC_KEY,
                "SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": False, "SURequireSignedFeed": True,
                "SUVerifyUpdateBeforeExtraction": True, "SUEnableInstallerLauncherService": True,
            }
            with (app / "Contents/Info.plist").open("wb") as stream:
                plistlib.dump(info, stream)
            self.run(["bash", ROOT / "Scripts/sign-app.sh", app, self.options.identity])
        archive = self.root / "Candidates.zip"
        self.run(["ditto", "-c", "-k", "--keepParent", self.root / "Candidates", archive])
        with (self.root / "notarization.json").open("w") as stream:
            self.run(["xcrun", "notarytool", "submit", archive, "--key", self.options.notary_key,
                      "--key-id", self.options.key_id, "--issuer", self.options.issuer,
                      "--wait", "--timeout", "40m", "--output-format", "json"], stdout=stream)
        response = json.loads((self.root / "notarization.json").read_text())
        if response.get("status") != "Accepted":
            raise RuntimeError("Apple did not accept the update proof fixtures")
        for version in (90, 91, 92, 93):
            app = self.root / "Candidates" / str(version) / "Fileel.app"
            self.run(["xcrun", "stapler", "staple", app])
            self.run(["xcrun", "stapler", "validate", app])

    def package_candidates(self):
        for version in (91, 92, 93):
            artifact = self.artifacts / f"Update-{version}.dmg"
            self.run(["hdiutil", "create", "-srcfolder", self.root / "Candidates" / str(version),
                      "-volname", "Fileel Update Test", "-format", "UDZO", "-fs", "HFS+", artifact])
            self.run(["codesign", "--sign", self.options.identity, "--timestamp", artifact])
            signature = self.run([self.tools / "sign_update", "--ed-key-file", self.options.ed_key_file,
                                  "-p", artifact], text=True, capture_output=True).stdout.strip()
            self.signatures[str(version)] = signature
            self.run(["swift", ROOT / "Scripts/VerifyUpdate.swift", artifact, release.PUBLIC_KEY, signature])
        altered = self.artifacts / "Altered-91.dmg"
        shutil.copy2(self.artifacts / "Update-91.dmg", altered)
        with altered.open("r+b") as stream:
            stream.seek(4096)
            value = stream.read(1)
            stream.seek(4096)
            stream.write(bytes([value[0] ^ 1]))
        invalid = subprocess.run(["swift", str(ROOT / "Scripts/VerifyUpdate.swift"), str(altered),
                                  release.PUBLIC_KEY, self.signatures["91"]], capture_output=True)
        if invalid.returncode == 0:
            raise AssertionError("the independent verifier accepted altered update bytes")

    def feed(self, channel, version, filename=None):
        path = self.server_root / channel / "appcast.xml"
        path.parent.mkdir(parents=True, exist_ok=True)
        root = ET.Element("rss", version="2.0")
        channel_node = ET.SubElement(root, "channel")
        ET.SubElement(channel_node, "title").text = "Fileel isolated update proof"
        item = ET.SubElement(channel_node, "item")
        ET.SubElement(item, "title").text = str(version)
        ET.SubElement(item, f"{{{SPARKLE}}}version").text = str(version)
        ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = "0.0.1"
        ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = "14.0"
        if channel == "beta":
            ET.SubElement(item, f"{{{SPARKLE}}}channel").text = "beta"
        filename = filename or f"Update-{version}.dmg"
        artifact = self.artifacts / filename
        ET.SubElement(item, "enclosure", {"url": f"{self.address}/artifacts/{filename}", "type": "application/octet-stream",
                                         "length": str(artifact.stat().st_size), f"{{{SPARKLE}}}edSignature": self.signatures[str(version)]})
        ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)
        self.run([self.tools / "sign_update", "--ed-key-file", self.options.ed_key_file, path], stdout=subprocess.DEVNULL)

    def preference(self, key, value):
        self.run(["defaults", "write", NAMESPACE, key, "-string", value], stdout=subprocess.DEVNULL)

    def installed_version(self):
        with (self.installed / "Contents/Info.plist").open("rb") as stream:
            return plistlib.load(stream)["CFBundleVersion"]

    def phase(self, name, expected, terminal_event, background=False):
        log = self.root / f"{name}.jsonl"
        configuration = self.root / "configuration.json"
        configuration.write_text(json.dumps({"server": self.address, "expectedBuild": str(expected),
                                             "log": str(log), "background": str(background).lower()}))
        self.preference("proofConfiguration", str(configuration))
        with (self.root / f"{name}-process.log").open("w") as output:
            process = subprocess.Popen([str(self.installed / "Contents/MacOS/UpdateSmokeHost")],
                                       env=self.child_env, stdout=output, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 190
            events = []
            while time.monotonic() < deadline:
                if log.exists():
                    events = [json.loads(line) for line in log.read_text().splitlines() if line.strip()]
                    if any(event["event"] in ("updated", "update-error", "not-found", "startup-error", "timeout") for event in events):
                        break
                time.sleep(0.25)
            if not any(event["event"] == terminal_event for event in events):
                raise AssertionError(f"{name} did not reach {terminal_event}: {events}")
            if terminal_event == "updated":
                event = next(event for event in events if event["event"] == "updated")
                if event["build"] != str(expected) or event["marker"] != "fileel-preserved-preferences":
                    raise AssertionError("the updated app lost its version or saved preferences")
                if self.installed_version() != str(expected):
                    raise AssertionError("the installed bundle did not advance")
                channel = "beta" if expected == 92 else "stable"
                boot = next(event for event in events if event["event"] == "launch" and event["build"] == str(expected))
                if boot["installed"] != channel or boot["selected"] != channel:
                    raise AssertionError("the relaunched app did not follow its installed channel")
                found = next(event for event in events if event["event"] == "found")
                if found["userInitiated"] != str(not background).lower():
                    raise AssertionError("the update did not use the requested background or manual path")
            process.wait(timeout=5)
            time.sleep(0.5)
            print(f"installed update proof: {name} passed", flush=True)
            return events
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)

    def exercise(self):
        http_log = self.root / "http.log"

        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, format, *arguments):
                with http_log.open("a") as stream:
                    stream.write(format % arguments + "\n")

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=str(self.server_root)))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.address = f"http://127.0.0.1:{server.server_port}"
        try:
            self.feed("stable", 91, "Altered-91.dmg")
            self.feed("beta", 92)
            self.installed.parent.mkdir()
            self.run(["ditto", self.root / "Candidates/90/Fileel.app", self.installed])
            self.preference("proofMarker", "fileel-preserved-preferences")
            self.preference("updateChannel", "stable")
            self.preference("installedUpdateChannel", "stable")
            negative = self.phase("reject-altered-download", 91, "update-error")
            rejection = next(event for event in negative if event["event"] == "update-error")
            if rejection["domain"] != "SUSparkleErrorDomain" or "sign" not in rejection["description"].lower():
                raise AssertionError("the altered update failed for a reason unrelated to signature validation")
            if self.installed_version() != "90" or any(event["event"] == "ready-to-install" for event in negative):
                raise AssertionError("the invalid update advanced to installation")
            self.feed("stable", 91)
            self.phase("install-stable", 91, "updated")
            self.preference("updateChannel", "beta")
            self.phase("enter-beta-in-background", 92, "updated", background=True)
            self.preference("updateChannel", "stable")
            events = self.phase("leave-beta-without-downgrade", 93, "not-found")
            if self.installed_version() != "92" or events[0].get("selected") != "stable":
                raise AssertionError("opting out of beta changed the installed version or ignored the preference")
            self.feed("stable", 93)
            self.phase("return-to-stable", 93, "updated")
            (self.root / "result.json").write_text(json.dumps({"status": "passed", "installedBuild": "93",
                                                            "signatureRejection": True, "preferencesRetained": True,
                                                            "betaRoundTrip": True, "backgroundCheck": True}, indent=2))
        finally:
            server.shutdown()
            server.server_close()


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--sparkle", type=Path, required=True)
    parser.add_argument("--ed-key-file", type=Path, required=True)
    parser.add_argument("--notary-key", type=Path, required=True)
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--issuer", required=True)
    parser.add_argument("--identity", default=release.IDENTITY)
    options = parser.parse_args()
    proof = UpdateProof(options)
    proof.build_candidates()
    proof.package_candidates()
    proof.exercise()


if __name__ == "__main__":
    main()
