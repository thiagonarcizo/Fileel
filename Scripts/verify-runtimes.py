#!/usr/bin/env python3
"""verify the runtime payload before sealing or publishing an app"""

import argparse
import json
from pathlib import Path
import re
import subprocess


REQUIRED = {"MacOS/ffmpeg", "MacOS/ffprobe", "MacOS/pandoc", "MacOS/gs", "MacOS/7zz",
            "Helpers/LibreOffice.app/Contents/MacOS/soffice"}
LOAD_COMMANDS = {"LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB", "LC_LOAD_UPWARD_DYLIB"}
MAGIC = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}


def inspect(path):
    result = subprocess.run(["lipo", "-archs", path], capture_output=True, text=True)
    # java class files share a fat mach-o magic, so confirm that the header is really native code
    if result.returncode:
        return None
    if "arm64" not in result.stdout.split():
        raise ValueError(f"{path.name} lacks native apple silicon support")
    metadata = subprocess.check_output(["xcrun", "vtool", "-arch", "arm64", "-show-build", path], text=True)
    match = re.search(r"\bminos\s+(\d+(?:\.\d+)+)", metadata)
    if not match:
        match = re.search(r"LC_VERSION_MIN_MACOSX.*?\bversion\s+(\d+(?:\.\d+)+)", metadata, re.DOTALL)
    if not match or tuple(map(int, match[1].split("."))) > (14, 0, 0):
        raise ValueError(f"{path.name} requires a macOS version above the app's supported minimum")
    commands = subprocess.check_output(["otool", "-arch", "arm64", "-l", path], text=True)
    current = ""
    for line in commands.splitlines():
        fields = line.strip().split()
        if fields[:1] == ["cmd"]:
            current = fields[1]
        if fields[:1] == ["name"] and current in LOAD_COMMANDS:
            dependency = fields[1]
            if not dependency.startswith(("/usr/lib/", "/System/Library/", "@rpath/", "@loader_path/", "@executable_path/")):
                raise ValueError(f"{path.name} depends on an external library: {dependency}")
    return match[1]


def verify(payload):
    manifest = json.loads((payload / "Resources/Engines/manifest.json").read_text())
    lock = json.loads((Path(__file__).resolve().parents[1] / "Distribution/runtime-lock.json").read_text())
    if manifest.get("schema") != 1 or manifest.get("components") != lock["components"]:
        raise ValueError("the bundled engines do not match the reviewed version lock")
    if set(manifest.get("executables", [])) != REQUIRED:
        raise ValueError("the bundle does not declare every required conversion engine")
    for executable in REQUIRED:
        path = payload / executable
        if not path.is_file() or not path.stat().st_mode & 0o111:
            raise ValueError(f"a required bundled executable is missing: {executable}")
    expected = {"ffmpeg", "ffprobe", "pandoc", "gs", "7zz"}
    if not expected.issubset({path.name for path in (payload / "MacOS").iterdir()}):
        raise ValueError("the standalone runtime directory is incomplete")
    count = 0
    roots = [payload / "MacOS" / name for name in expected]
    roots.extend((payload / "Helpers/LibreOffice.app").rglob("*"))
    for path in roots:
        if not path.is_file() or path.is_symlink():
            continue
        with path.open("rb") as stream:
            magic = stream.read(4)
        if magic in MAGIC and inspect(path) is not None:
            count += 1
    if count < 6:
        raise ValueError("the runtime inventory did not contain the expected native programs")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", payload / "Helpers/LibreOffice.app"], check=True)
    print(f"verified {count} native runtime components for macOS 14 and apple silicon")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("payload", type=Path)
    verify(parser.parse_args().payload.resolve())
