#!/usr/bin/env python3
import base64
from concurrent.futures import ThreadPoolExecutor
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import xml.etree.ElementTree as ET
from email.utils import format_datetime


# keep release routing and the update trust root independent of user-supplied workflow text
ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = "thiagonarcizo/Fileel"
PUBLIC_KEY = "nMA9rtIbe4Be4GX9EsRMc9w6iHfiNVcVa0JXb++TIAc="
TEAM = "TQ87ZCU6H5"
IDENTITY = "Developer ID Application: Lucas Baggiotto (TQ87ZCU6H5)"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def run(args, **kwargs):
    result = subprocess.run([str(x) for x in args], **kwargs)
    if result.returncode:
        # never include subprocess arguments here, since keychain commands contain credentials
        raise RuntimeError(f"{Path(args[0]).name} failed with exit code {result.returncode}")
    return result


def capture(args, **kwargs):
    return run(args, text=True, capture_output=True, **kwargs).stdout.strip()


def build_tuple(value):
    if not re.fullmatch(r"[1-9]\d*(?:\.\d+){0,2}", value):
        raise ValueError("invalid numeric build version")
    parts = tuple(int(x) for x in value.split("."))
    return parts + (0,) * (3 - len(parts))


def release_plan(branch, run_number, attempt, sha, marketing):
    if branch not in ("main", "dev"):
        raise ValueError("only main and dev can publish")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("a full source commit is required")
    if not re.fullmatch(r"\d+\.\d+\.\d+", marketing):
        raise ValueError("use a three-component marketing version")
    if int(run_number) < 1 or not 1 <= int(attempt) <= 99:
        raise ValueError("invalid workflow run number or attempt")
    channel = "stable" if branch == "main" else "beta"
    build = f"{100 + int(run_number)}.{int(attempt)}"
    tag = f"v{marketing}-{build}" + ("-beta" if channel == "beta" else "")
    return dict(branch=branch, channel=channel, build=build, marketing=marketing,
                sha=sha, tag=tag, filename=f"Fileel-{marketing}-{build}-{channel}-arm64.dmg")


def empty_feed(channel):
    root = ET.Element("rss", version="2.0")
    node = ET.SubElement(root, "channel")
    ET.SubElement(node, "title").text = "Fileel" + (" Beta" if channel == "beta" else "")
    ET.SubElement(node, "description").text = "Verified Fileel updates for Apple Silicon"
    ET.SubElement(node, "language").text = "en"
    return root


def read_feed(path, channel):
    if not path.exists():
        return empty_feed(channel)
    root = ET.parse(path).getroot()
    if root.tag != "rss" or root.find("channel") is None:
        raise ValueError("invalid existing update feed")
    return root


def append_release(root, plan, signature, size):
    if len(base64.b64decode(signature, validate=True)) != 64 or size <= 0:
        raise ValueError("invalid update signature or size")
    channel = root.find("channel")
    for entry in channel.findall("item"):
        previous = entry.findtext(f"{{{SPARKLE}}}version")
        if not previous or build_tuple(previous) >= build_tuple(plan["build"]):
            raise ValueError("refusing a duplicate, stale or unversioned update")
    item = ET.Element("item")
    label = "Fileel Beta" if plan["channel"] == "beta" else "Fileel"
    ET.SubElement(item, "title").text = f"{label} {plan['marketing']} ({plan['build']})"
    ET.SubElement(item, "pubDate").text = format_datetime(dt.datetime.now(dt.timezone.utc))
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = plan["build"]
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = plan["marketing"]
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = "14.0"
    if plan["channel"] == "beta":
        ET.SubElement(item, f"{{{SPARKLE}}}channel").text = "beta"
    ET.SubElement(item, "link").text = f"https://github.com/{REPOSITORY}/releases/tag/{plan['tag']}"
    ET.SubElement(item, "description").text = "See the release notes for changes in this version."
    ET.SubElement(item, "enclosure", {
        "url": f"https://github.com/{REPOSITORY}/releases/download/{plan['tag']}/{plan['filename']}",
        "type": "application/octet-stream", "length": str(size),
        f"{{{SPARKLE}}}edSignature": signature,
    })
    channel.insert(0, item)
    for entry in channel.findall("item")[10:]:
        channel.remove(entry)


def save_feed(root, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    ET.indent(root)
    ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)


def workspace():
    directory = Path(os.environ["RUNNER_TEMP"]) / "fileel-release"
    directory.mkdir(mode=0o700, exist_ok=True)
    return directory


def plan_release():
    if os.environ.get("GITHUB_REPOSITORY") != REPOSITORY:
        raise ValueError("release automation is restricted to the upstream repository")
    values = set(re.findall(r"MARKETING_VERSION = ([^;]+);", (ROOT / "Fileel.xcodeproj/project.pbxproj").read_text()))
    if len(values) != 1:
        raise ValueError("all configurations must use the same marketing version")
    plan = release_plan(os.environ["GITHUB_REF_NAME"], os.environ["GITHUB_RUN_NUMBER"],
                        os.environ["GITHUB_RUN_ATTEMPT"], os.environ["GITHUB_SHA"], values.pop())
    current = source_is_current(plan)
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a") as stream:
            stream.write(f"current={'true' if current else 'false'}\n")
    if not current:
        print("::notice::A newer source commit superseded this delivery; its queued run will build the current version")
        return
    (workspace() / "plan.json").write_text(json.dumps(plan, indent=2))
    print(f"planned {plan['channel']} {plan['marketing']} ({plan['build']}) at {plan['sha']}")


def secret_file(path, value):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(value)


def notarize(path, credential_dir, output):
    # the api key stays in a private temporary file, never in an argument or artifact
    args = ["xcrun", "notarytool", "submit", path, "--key", credential_dir / "AuthKey.p8",
            "--key-id", os.environ["ASC_KEY_ID"], "--issuer", os.environ["ASC_ISSUER_ID"],
            "--wait", "--timeout", "40m", "--output-format", "json"]
    with output.open("w") as stream:
        run(args, stdout=stream)
    response = json.loads(output.read_text())
    if response.get("status") != "Accepted":
        raise RuntimeError("Apple did not accept the submission; no release will be published")


def verify_signature(path, signature):
    run(["swift", ROOT / "Scripts/VerifyUpdate.swift", path, PUBLIC_KEY, signature])


def verify_app_info(info, plan=None):
    branch = info.get("FileelUpdateBranch")
    if branch not in ("main", "dev"):
        raise ValueError("the archived app is missing its update channel")
    channel = "stable" if branch == "main" else "beta"
    expected = f"https://raw.githubusercontent.com/{REPOSITORY}/updates/{channel}/appcast.xml"
    if info.get("SUPublicEDKey") != PUBLIC_KEY or info.get("SUFeedURL") != expected:
        raise ValueError("the app has incorrect update trust or feed metadata")
    for key in ("SUEnableAutomaticChecks", "SUEnableInstallerLauncherService", "SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"):
        if info.get(key) is not True:
            raise ValueError(f"the app is missing the boolean update policy {key}")
    if info.get("LSUIElement") is not True or info.get("CFBundleIdentifier") != "xyz.narcizo.Fileel":
        raise ValueError("the app has incorrect menu-bar or bundle identity metadata")
    if info.get("SUScheduledCheckInterval") != 3600:
        raise ValueError("the app is missing the scheduled update interval")
    build_tuple(info.get("CFBundleVersion", ""))
    if plan and (info.get("CFBundleVersion") != plan["build"] or branch != plan["branch"]
                 or info.get("CFBundleShortVersionString") != plan["marketing"]):
        raise ValueError("the archived app has an incorrect release version or channel")


def sparkle_tool(directory):
    tools = list((directory / "DerivedData/SourcePackages/artifacts/sparkle").glob("*/bin/sign_update"))
    if len(tools) != 1:
        raise ValueError("could not identify the resolved Sparkle signing tool")
    return tools[0]


def build_release():
    required = ["FILEEL_CERTIFICATE_P12", "FILEEL_CERTIFICATE_PASSWORD", "ASC_KEY_ID",
                "ASC_ISSUER_ID", "ASC_PRIVATE_KEY", "FILEEL_SPARKLE_PRIVATE_KEY"]
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        raise ValueError("missing protected environment secrets: " + ", ".join(missing))
    directory = workspace()
    plan = json.loads((directory / "plan.json").read_text())
    payload = ROOT / "build/runtime/payload"
    sources = ROOT / "build/runtime/Fileel-Runtime-Sources.tar"
    # validate public build inputs before importing any private signing material
    run(["python3", ROOT / "Scripts/verify-runtimes.py", payload])
    if not sources.is_file():
        raise ValueError("the corresponding runtime source archive is missing")
    derived = directory / "DerivedData"
    archive = directory / "Fileel.xcarchive"
    output = directory / "public"
    output.mkdir()
    previous_keychains = shlex.split(capture(["security", "list-keychains", "-d", "user"]))
    with tempfile.TemporaryDirectory(prefix="fileel-signing-", dir=os.environ["RUNNER_TEMP"]) as temp:
        credentials = Path(temp)
        keychain = credentials / "signing.keychain-db"
        password = secrets.token_urlsafe(32)
        secret_file(credentials / "certificate.p12", base64.b64decode(os.environ["FILEEL_CERTIFICATE_P12"], validate=True))
        secret_file(credentials / "AuthKey.p8", base64.b64decode(os.environ["ASC_PRIVATE_KEY"], validate=True))
        try:
            run(["security", "create-keychain", "-p", password, keychain], stdout=subprocess.DEVNULL)
            run(["security", "set-keychain-settings", "-lut", "7200", keychain])
            run(["security", "unlock-keychain", "-p", password, keychain])
            run(["security", "import", credentials / "certificate.p12", "-k", keychain,
                 "-P", os.environ["FILEEL_CERTIFICATE_PASSWORD"], "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"], stdout=subprocess.DEVNULL)
            run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", password, keychain], stdout=subprocess.DEVNULL)
            run(["security", "list-keychains", "-d", "user", "-s", keychain, *previous_keychains])
            identities = capture(["security", "find-identity", "-v", "-p", "codesigning", keychain])
            if IDENTITY not in identities:
                raise ValueError("the certificate does not match the expected Developer ID team")
            run(["xcodebuild", "archive", "-project", "Fileel.xcodeproj", "-scheme", "Fileel",
                 "-configuration", "Release", "-destination", "generic/platform=macOS",
                 "-archivePath", archive, "-derivedDataPath", derived,
                 "CODE_SIGN_STYLE=Manual", f"CODE_SIGN_IDENTITY={IDENTITY}", f"DEVELOPMENT_TEAM={TEAM}",
                 f"CURRENT_PROJECT_VERSION={plan['build']}", f"FILEEL_UPDATE_BRANCH={plan['branch']}",
                 f"FILEEL_UPDATE_CHANNEL={plan['channel']}",
                 "OTHER_CODE_SIGN_FLAGS=--timestamp"])
            app = archive / "Products/Applications/Fileel.app"
            for folder in ("MacOS", "Helpers", "Resources"):
                run(["ditto", payload / folder, app / "Contents" / folder])
            run(["bash", ROOT / "Scripts/sign-app.sh", app, IDENTITY])
            with (app / "Contents/Info.plist").open("rb") as stream:
                info = plistlib.load(stream)
            verify_app_info(info, plan)
            # a public download must contain the engines promised by the app, not rely on homebrew
            manifest = app / "Contents/Resources/Engines/manifest.json"
            if not manifest.is_file():
                raise ValueError("bundled conversion engines are missing; refusing an incomplete public release")
            secret_file(credentials / "Sparkle.key", os.environ["FILEEL_SPARKLE_PRIVATE_KEY"].encode())
            # exercise the real installer and channel migration in a separate, disposable app identity
            run(["python3", ROOT / "Scripts/test-installed-updates.py", "--directory", directory / "update-proof",
                 "--sparkle", sparkle_tool(directory).parents[1], "--ed-key-file", credentials / "Sparkle.key",
                 "--notary-key", credentials / "AuthKey.p8", "--key-id", os.environ["ASC_KEY_ID"],
                 "--issuer", os.environ["ASC_ISSUER_ID"], "--identity", IDENTITY])
            run(["codesign", "--verify", "--deep", "--strict", app])
            package = directory / "notarization.zip"
            run(["ditto", "-c", "-k", "--keepParent", app, package])
            notarize(package, credentials, directory / "app-notarization.json")
            run(["xcrun", "stapler", "staple", app])
            run(["xcrun", "stapler", "validate", app])
            run(["spctl", "--assess", "--type", "execute", app])
            dmg = output / plan["filename"]
            run(["bash", ROOT / "Scripts/create-dmg.sh", app, dmg],
                env={**os.environ, "FILEEL_SIGNING_IDENTITY": IDENTITY, "FILEEL_RELEASE_CHANNEL": plan["channel"]})
            notarize(dmg, credentials, directory / "dmg-notarization.json")
            run(["xcrun", "stapler", "staple", dmg])
            run(["xcrun", "stapler", "validate", dmg])
            run(["hdiutil", "verify", dmg])
            signature = capture([sparkle_tool(directory), "--ed-key-file", "-", "-p", dmg], input=os.environ["FILEEL_SPARKLE_PRIVATE_KEY"])
            verify_signature(dmg, signature)
            plan.update(signature=signature, size=dmg.stat().st_size, sha256=hashlib.file_digest(dmg.open("rb"), "sha256").hexdigest())
            (directory / "plan.json").write_text(json.dumps(plan, indent=2))
            (output / (plan["filename"] + ".sha256")).write_text(f"{plan['sha256']}  {plan['filename']}\n")
            (output / "release.json").write_text(json.dumps(plan, indent=2) + "\n")
            shutil.copy2(sources, output / sources.name)
            with sources.open("rb") as stream:
                checksum = hashlib.file_digest(stream, "sha256").hexdigest()
            (output / (sources.name + ".sha256")).write_text(f"{checksum}  {sources.name}\n")
        finally:
            run(["security", "list-keychains", "-d", "user", "-s", *previous_keychains], stdout=subprocess.DEVNULL)
            subprocess.run(["security", "delete-keychain", str(keychain)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def gh_json(args):
    return json.loads(capture(["gh", *args]))


def source_is_current(plan):
    if plan["branch"] not in ("main", "dev") or not re.fullmatch(r"[0-9a-f]{40}", plan["sha"]):
        raise ValueError("invalid release source")
    branch = gh_json(["api", f"repos/{REPOSITORY}/git/ref/heads/{plan['branch']}"])
    return branch["object"]["sha"] == plan["sha"]


def rehearsal_tag(run_id, attempt):
    if not re.fullmatch(r"[1-9]\d*", run_id) or not re.fullmatch(r"[1-9]\d*", attempt):
        raise ValueError("a rehearsal requires a valid workflow run and attempt")
    return f"ci-verification-{run_id}-{attempt}"


def rehearse_release():
    directory = workspace()
    plan = json.loads((directory / "plan.json").read_text())
    if os.environ.get("GITHUB_EVENT_NAME") not in ("workflow_dispatch", "push") or os.environ.get("GITHUB_REPOSITORY") != REPOSITORY:
        raise ValueError("private distribution verification requires an upstream delivery run")
    if plan["sha"] != os.environ.get("GITHUB_SHA") or plan["branch"] not in ("main", "dev"):
        raise ValueError("the verification source does not match the reviewed branch")
    tag = rehearsal_tag(os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_RUN_ATTEMPT"])
    reference = f"refs/tags/{tag}"
    matching = gh_json(["api", f"repos/{REPOSITORY}/git/matching-refs/tags/{tag}"])
    if any(item["ref"] == reference for item in matching):
        raise ValueError("the verification tag already exists; refusing to reuse it")
    public = directory / "public"
    names = [plan["filename"], plan["filename"] + ".sha256", "release.json",
             "Fileel-Runtime-Sources.tar", "Fileel-Runtime-Sources.tar.sha256"]
    assets = [public / name for name in names]
    if not all(asset.is_file() for asset in assets):
        raise ValueError("a verification artifact is missing")
    # drafts stay private to repository maintainers and never touch either signed update feed
    run(["gh", "release", "create", tag, *assets, "--repo", REPOSITORY, "--target", plan["sha"],
         "--title", "Private Fileel distribution verification", "--notes",
         "Temporary signed-build verification. This draft is removed after upload checks.", "--draft", "--prerelease"])
    try:
        downloaded = directory / "verification-download"
        downloaded.mkdir()
        run(["gh", "release", "download", tag, "--repo", REPOSITORY, "--dir", downloaded])
        for name in names:
            with (public / name).open("rb") as source, (downloaded / name).open("rb") as remote:
                if hashlib.file_digest(source, "sha256").digest() != hashlib.file_digest(remote, "sha256").digest():
                    raise ValueError("a downloaded verification artifact differs from the original")
        verify_signature(downloaded / plan["filename"], plan["signature"])
        rehearse_feed_publication(directory, plan, tag)
        print("private signed/notarized upload and download verification passed; update feeds are unchanged")
    finally:
        # this run created the unique draft, so cleanup cannot remove an existing public release
        run(["gh", "release", "delete", tag, "--repo", REPOSITORY, "--yes"])
        matching = gh_json(["api", f"repos/{REPOSITORY}/git/matching-refs/tags/{tag}"])
        for item in matching:
            if item["ref"] == reference:
                if item["object"].get("type") != "commit" or item["object"].get("sha") != plan["sha"]:
                    raise ValueError("the verification tag changed unexpectedly; leaving it untouched")
                run(["gh", "api", "--method", "DELETE", f"repos/{REPOSITORY}/git/{reference}"])


def prepare_channel_feed(feeds, plan, verifier):
    if plan["channel"] not in ("stable", "beta"):
        raise ValueError("invalid update channel")
    path = feeds / plan["channel"] / "appcast.xml"
    if path.exists():
        verifier(path)
    root = read_feed(path, plan["channel"])
    first = root.find("channel/item")
    if first is not None and first.findtext(f"{{{SPARKLE}}}version") == plan["build"]:
        enclosure = first.find("enclosure")
        expected = {
            "url": f"https://github.com/{REPOSITORY}/releases/download/{plan['tag']}/{plan['filename']}",
            "length": str(plan["size"]), f"{{{SPARKLE}}}edSignature": plan["signature"],
        }
        if enclosure is None or any(enclosure.get(key) != value for key, value in expected.items()) \
                or first.findtext(f"{{{SPARKLE}}}shortVersionString") != plan["marketing"] \
                or first.findtext(f"{{{SPARKLE}}}minimumSystemVersion") != "14.0" \
                or first.findtext("link") != f"https://github.com/{REPOSITORY}/releases/tag/{plan['tag']}" \
                or first.findtext(f"{{{SPARKLE}}}channel") != ("beta" if plan["channel"] == "beta" else None):
            raise ValueError("the published build has different update metadata")
    else:
        # channels progress independently; sparkle still refuses a downgrade when switching between them
        append_release(root, plan, plan["signature"], plan["size"])
    save_feed(root, path)
    return path


def advance_channel_feed(feeds, plan, signer, verifier, attempts=5, branch="updates"):
    if branch != "updates" and not re.fullmatch(r"ci-feed-verification-[1-9]\d*-[1-9]\d*", branch):
        raise ValueError("feed publication cannot modify an application branch")
    run(["git", "-C", feeds, "config", "user.name", "github-actions[bot]"])
    run(["git", "-C", feeds, "config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com"])
    run(["git", "-C", feeds, "config", "commit.gpgsign", "false"])
    for attempt in range(attempts):
        run(["git", "-C", feeds, "fetch", "--depth=1", "origin", branch])
        # only reset this disposable feed checkout, never the application workspace
        run(["git", "-C", feeds, "reset", "--hard", "FETCH_HEAD"])
        path = prepare_channel_feed(feeds, plan, verifier)
        signer(path)
        run(["git", "-C", feeds, "add", f"{plan['channel']}/appcast.xml"])
        changed = subprocess.run(["git", "-C", str(feeds), "diff", "--cached", "--quiet", "--", f"{plan['channel']}/appcast.xml"])
        if changed.returncode == 0:
            return capture(["git", "-C", feeds, "rev-parse", "HEAD"])
        if changed.returncode != 1:
            raise RuntimeError("could not inspect the prepared update feed")
        run(["git", "-C", feeds, "commit", "-m", f"Publish {plan['channel']} update {plan['build']}"])
        result = subprocess.run(["git", "-C", str(feeds), "push", "origin", f"HEAD:refs/heads/{branch}"], capture_output=True, text=True)
        if result.returncode == 0:
            return capture(["git", "-C", feeds, "rev-parse", "HEAD"])
        # another channel may have advanced the shared branch while this feed was being signed
        print(f"feed publication did not advance; refreshing before retry {attempt + 1}/{attempts}")
    raise RuntimeError("could not advance the update feed after concurrent publication retries")


def rehearse_feed_publication(directory, plan, tag):
    branch = rehearsal_tag(os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_RUN_ATTEMPT"]).replace("ci-verification-", "ci-feed-verification-", 1)
    reference = f"refs/heads/{branch}"
    matching = gh_json(["api", f"repos/{REPOSITORY}/git/matching-refs/heads/{branch}"])
    if any(item["ref"] == reference for item in matching):
        raise ValueError("the feed verification branch already exists; refusing to reuse it")
    source = gh_json(["api", f"repos/{REPOSITORY}/git/ref/heads/updates"])["object"]["sha"]
    signing_key = os.environ["FILEEL_SPARKLE_PRIVATE_KEY"]
    def verify(path):
        capture([sparkle_tool(directory), "--ed-key-file", "-", "--verify", path], input=signing_key)

    def sign(path):
        capture([sparkle_tool(directory), "--ed-key-file", "-", path], input=signing_key)
        verify(path)

    run(["gh", "auth", "setup-git"])
    gh_json(["api", "--method", "POST", f"repos/{REPOSITORY}/git/refs", "-f", f"ref={reference}", "-f", f"sha={source}"])
    allowed_heads = {source}
    lock = threading.Lock()
    try:
        with tempfile.TemporaryDirectory(prefix="fileel-feed-proof-", dir=os.environ["RUNNER_TEMP"]) as temp:
            root = Path(temp)
            seed = root / "seed"
            remote = f"https://github.com/{REPOSITORY}.git"
            run(["git", "clone", "--quiet", "--depth=1", "--branch", branch, remote, seed])
            for channel in ("stable", "beta"):
                path = seed / channel / "appcast.xml"
                save_feed(empty_feed(channel), path)
                sign(path)
            # the isolated branch always gets a seed commit, even before either public feed has a release
            (seed / ".feed-verification.json").write_text(json.dumps({"run": os.environ["GITHUB_RUN_ID"], "attempt": os.environ["GITHUB_RUN_ATTEMPT"]}))
            run(["git", "-C", seed, "add", "stable/appcast.xml", "beta/appcast.xml", ".feed-verification.json"])
            run(["git", "-C", seed, "-c", "user.name=github-actions[bot]", "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
                 "-c", "commit.gpgsign=false", "commit", "-m", "Initialize isolated feed verification"])
            run(["git", "-C", seed, "push", "origin", f"HEAD:{reference}"])
            allowed_heads.add(capture(["git", "-C", seed, "rev-parse", "HEAD"]))
            plans = [dict(plan, channel=channel, branch="main" if channel == "stable" else "dev", tag=tag) for channel in ("stable", "beta")]
            checkouts = []
            for channel in ("stable", "beta"):
                checkout = root / channel
                run(["git", "clone", "--quiet", "--depth=1", "--branch", branch, remote, checkout])
                checkouts.append(checkout)
            barrier = threading.Barrier(2)
            counts = [0, 0]

            def publish(index):
                def synchronized_sign(path):
                    sign(path)
                    counts[index] += 1
                    if counts[index] == 1:
                        barrier.wait(timeout=60)
                head = advance_channel_feed(checkouts[index], plans[index], synchronized_sign, verify, branch=branch)
                with lock:
                    allowed_heads.add(head)

            with ThreadPoolExecutor(max_workers=2) as workers:
                futures = [workers.submit(publish, index) for index in range(2)]
                for future in futures:
                    future.result()
            if sum(counts) < 3:
                raise ValueError("the feed publication race did not exercise a rejected push")
            # replaying the same artifact must succeed without duplicating its appcast item
            allowed_heads.add(advance_channel_feed(checkouts[0], plans[0], sign, verify, branch=branch))
            for candidate in plans:
                channel = candidate["channel"]
                downloaded = gh_json(["api", f"repos/{REPOSITORY}/contents/{channel}/appcast.xml?ref={branch}"])
                path = root / f"downloaded-{channel}.xml"
                path.write_bytes(base64.b64decode(downloaded["content"]))
                verify(path)
                feed = ET.parse(path).getroot()
                if len(feed.findall("channel/item")) != 1 or feed.findtext(f"channel/item/{{{SPARKLE}}}version") != candidate["build"]:
                    raise ValueError("a channel feed was lost or duplicated during concurrent publication")
            print("private signed feed publication, concurrent retry and replay verification passed")
    finally:
        current = gh_json(["api", f"repos/{REPOSITORY}/git/ref/heads/{branch}"])["object"]["sha"]
        if current not in allowed_heads:
            raise ValueError("the feed verification branch changed unexpectedly; leaving it untouched")
        run(["gh", "api", "--method", "DELETE", f"repos/{REPOSITORY}/git/refs/heads/{branch}"])


def publish_release():
    if os.environ.get("FILEEL_RELEASE_READY") != "true":
        raise ValueError("public release acceptance is still locked; use a private verification run")
    directory = workspace()
    plan = json.loads((directory / "plan.json").read_text())
    if os.environ.get("GITHUB_REPOSITORY") != REPOSITORY or plan["sha"] != os.environ.get("GITHUB_SHA"):
        raise ValueError("release provenance does not match this workflow")
    if not source_is_current(plan):
        print("::notice::This delivery was superseded; leaving its channel feed unchanged")
        return
    run(["gh", "auth", "setup-git"])
    with tempfile.TemporaryDirectory(prefix="fileel-feeds-", dir=os.environ["RUNNER_TEMP"]) as temp:
        feeds = Path(temp)
        run(["git", "init", "-q", feeds])
        run(["git", "-C", feeds, "remote", "add", "origin", f"https://github.com/{REPOSITORY}.git"])
        # fetch only data from the publication branch, never execute its contents
        run(["git", "-C", feeds, "fetch", "--depth=1", "origin", "updates"])
        run(["git", "-C", feeds, "checkout", "-q", "-b", "updates", "FETCH_HEAD"])
        # authenticate the feed too, so a repository-only compromise cannot rewrite update metadata
        signing_key = os.environ["FILEEL_SPARKLE_PRIVATE_KEY"]
        def verify_feed(path):
            capture([sparkle_tool(directory), "--ed-key-file", "-", "--verify", path], input=signing_key)

        def sign_feed(path):
            capture([sparkle_tool(directory), "--ed-key-file", "-", path], input=signing_key)
            verify_feed(path)

        sign_feed(prepare_channel_feed(feeds, plan, verify_feed))
        title = f"Fileel{' Beta' if plan['channel'] == 'beta' else ''} {plan['marketing']} ({plan['build']})"
        assets = [directory / "public" / name for name in (plan["filename"], plan["filename"] + ".sha256", "release.json",
                                                          "Fileel-Runtime-Sources.tar", "Fileel-Runtime-Sources.tar.sha256")]
        for asset in assets:
            if not asset.is_file():
                raise ValueError("a public release artifact is missing")
        # draft first, then verify github's downloaded copy before exposing it to users
        run(["gh", "release", "create", plan["tag"], *assets, "--repo", REPOSITORY,
             "--target", plan["sha"], "--title", title, "--generate-notes", "--draft"])
        downloaded = directory / "downloaded"
        downloaded.mkdir()
        run(["gh", "release", "download", plan["tag"], "--repo", REPOSITORY,
             "--pattern", plan["filename"], "--dir", downloaded])
        dmg = downloaded / plan["filename"]
        with dmg.open("rb") as stream:
            if hashlib.file_digest(stream, "sha256").hexdigest() != plan["sha256"]:
                raise ValueError("the uploaded update differs from the verified local artifact")
        verify_signature(dmg, plan["signature"])
        if not source_is_current(plan):
            draft = gh_json(["api", f"repos/{REPOSITORY}/releases/tags/{plan['tag']}"])
            if not draft.get("draft") or draft.get("target_commitish") != plan["sha"]:
                raise ValueError("the superseded release changed unexpectedly; leaving it untouched")
            run(["gh", "api", "--method", "DELETE", f"repos/{REPOSITORY}/releases/{draft['id']}"])
            print("::notice::A newer source superseded this verified draft; its queued run will publish")
            return
        run(["gh", "release", "edit", plan["tag"], "--repo", REPOSITORY, "--draft=false",
             f"--prerelease={'true' if plan['channel'] == 'beta' else 'false'}",
             f"--latest={'false' if plan['channel'] == 'beta' else 'true'}"])
        advance_channel_feed(feeds, plan, sign_feed, verify_feed)
        published = gh_json(["api", f"repos/{REPOSITORY}/contents/{plan['channel']}/appcast.xml?ref=updates"])
        remote = ET.fromstring(base64.b64decode(published["content"]))
        if remote.findtext(f"channel/item/{{{SPARKLE}}}version") != plan["build"]:
            raise ValueError("the public update feed did not advance to the verified release")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as stream:
            stream.write(f"### {title}\n\nSigned, notarized and published from `{plan['sha']}`\n\n"
                         f"[Download and release notes](https://github.com/{REPOSITORY}/releases/tag/{plan['tag']})\n\n"
                         "The channel feed now advertises this verified update. Apps discover it on their next scheduled check\n")


if __name__ == "__main__":
    try:
        os.umask(0o077)
        commands = {"plan": plan_release, "build": build_release, "publish": publish_release, "rehearse": rehearse_release}
        if len(sys.argv) == 3 and sys.argv[1] == "verify-bundle":
            with (Path(sys.argv[2]) / "Contents/Info.plist").open("rb") as stream:
                verify_app_info(plistlib.load(stream))
            print("the built app contains the expected update configuration")
            sys.exit(0)
        if len(sys.argv) != 2 or sys.argv[1] not in commands:
            raise ValueError("usage: release.py plan|build|publish|rehearse")
        commands[sys.argv[1]]()
    except (ValueError, RuntimeError, KeyError, OSError) as error:
        print(f"::error::{error}", file=sys.stderr)
        sys.exit(1)
