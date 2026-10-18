#!/usr/bin/env python3
"""build the pinned, relocatable macos conversion tools before importing signing keys"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import urllib.parse
import zipfile


ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "Distribution/runtime-lock.json"


class RuntimeBuilder:
    def __init__(self, directory):
        self.root = directory.resolve()
        self.lock = json.loads(LOCK.read_text())
        self.prefix = self.root / "prefix"
        self.sources = self.root / "sources"
        self.downloads = self.root / "downloads"
        self.logs = self.root / "logs"
        self.output = self.root / "payload"
        self.jobs = str(min(os.cpu_count() or 2, 8))
        for path in (self.prefix, self.sources, self.downloads, self.logs, self.output):
            path.mkdir(parents=True, exist_ok=True)
        # vendor configure scripts never inherit release credentials or github tokens
        self.env = {key: os.environ[key] for key in ("HOME", "TMPDIR", "DEVELOPER_DIR") if key in os.environ}
        self.env.update({
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "MACOSX_DEPLOYMENT_TARGET": self.lock["minimum_macos"],
            "CFLAGS": "-O2 -mmacosx-version-min=14.0",
            "CXXFLAGS": "-O2 -mmacosx-version-min=14.0",
            "LDFLAGS": "-mmacosx-version-min=14.0",
            "PKG_CONFIG_LIBDIR": str(self.prefix / "lib/pkgconfig"),
            "PKG_CONFIG_PATH": str(self.prefix / "lib/pkgconfig"),
            "GIT_TERMINAL_PROMPT": "0",
            "LC_ALL": "C",
        })
        self.env["SDKROOT"] = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()

    def run(self, name, args, cwd=None):
        with (self.logs / f"{name}.log").open("a") as log:
            log.write("\n" + " ".join(map(str, args)) + "\n")
            log.flush()
            result = subprocess.run(list(map(str, args)), cwd=cwd, env=self.env, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(f"{name} failed; see {self.logs / (name + '.log')}")

    def download(self, name):
        return self.download_spec(name, self.lock["components"][name])

    def download_spec(self, name, info):
        digest = info.get("sha256")
        if not digest or len(digest) != 64:
            raise ValueError(f"{name} must have an immutable source checksum")
        path = self.downloads / info.get("filename", Path(urllib.parse.urlparse(info["url"]).path).name)
        if not path.exists():
            pending = path.with_name(path.name + ".partial")
            self.run(name, ["curl", "--fail", "--location", "--retry", "3", "--silent", "--show-error", info["url"], "--output", pending])
            pending.rename(path)
        with path.open("rb") as stream:
            actual = hashlib.file_digest(stream, "sha256").hexdigest()
        if actual != digest:
            raise ValueError(f"{name} failed its source checksum")
        return path

    def source(self, name):
        info = self.lock["components"][name]
        target = self.sources / name
        if "revision" in info:
            checkout = self.root / f"{name}-source"
            if not checkout.exists():
                self.run(name, ["git", "clone", "--depth", "1", "--branch", info["tag"], info["url"], checkout])
            revision = subprocess.check_output(["git", "-C", checkout, "rev-parse", "HEAD"], text=True, env=self.env).strip()
            if revision != info["revision"]:
                raise ValueError(f"{name} does not match the pinned upstream revision")
            return checkout
        archive = self.download(name)
        marker = target / ".fileel-source-sha256"
        if marker.exists() and marker.read_text() == info["sha256"]:
            return self.source_root(target)
        if target.exists():
            shutil.rmtree(target)
        target.mkdir()
        if zipfile.is_zipfile(archive):
            with zipfile.ZipFile(archive) as bundle:
                for entry in bundle.infolist():
                    if not (target / entry.filename).resolve().is_relative_to(target.resolve()):
                        raise ValueError("an archive member escapes its source directory")
                bundle.extractall(target)
        else:
            # the data filter rejects device nodes and links outside the source tree
            with tarfile.open(archive) as bundle:
                bundle.extractall(target, filter="data")
        marker.write_text(info["sha256"])
        return self.source_root(target)

    @staticmethod
    def source_root(target):
        entries = [entry for entry in target.iterdir() if not entry.name.startswith(".")]
        return entries[0] if len(entries) == 1 and entries[0].is_dir() else target

    def completed(self, name):
        marker = self.root / "completed" / name
        return marker.is_file() and marker.read_text() == json.dumps(self.lock["components"][name], sort_keys=True)

    def complete(self, name):
        marker = self.root / "completed" / name
        marker.parent.mkdir(exist_ok=True)
        marker.write_text(json.dumps(self.lock["components"][name], sort_keys=True))
        print(f"{name}: built", flush=True)

    def cmake(self, name, arguments):
        source = self.source(name)
        build = self.root / "cmake" / name
        self.run(name, ["cmake", "-S", source, "-B", build, "-G", "Ninja",
                       "-DCMAKE_BUILD_TYPE=Release", f"-DCMAKE_INSTALL_PREFIX={self.prefix}",
                       "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0",
                       "-DCMAKE_POLICY_VERSION_MINIMUM=3.5", "-DBUILD_SHARED_LIBS=OFF", *arguments])
        self.run(name, ["cmake", "--build", build, "--parallel", self.jobs])
        self.run(name, ["cmake", "--install", build])

    def configure(self, name, arguments):
        source = self.source(name)
        self.run(name, [source / "configure", f"--prefix={self.prefix}", *arguments], source)
        self.run(name, ["make", "-j", self.jobs], source)
        self.run(name, ["make", "install"], source)

    def build_codec(self, name):
        if self.completed(name):
            return
        if name == "aom":
            self.cmake(name, ["-DENABLE_TESTS=OFF", "-DENABLE_EXAMPLES=OFF", "-DENABLE_TOOLS=OFF", "-DENABLE_DOCS=OFF"])
        elif name == "webp":
            self.cmake(name, ["-DWEBP_BUILD_ANIM_UTILS=OFF", "-DWEBP_BUILD_CWEBP=OFF", "-DWEBP_BUILD_DWEBP=OFF",
                              "-DWEBP_BUILD_GIF2WEBP=OFF", "-DWEBP_BUILD_IMG2WEBP=OFF", "-DWEBP_BUILD_VWEBP=OFF",
                              "-DWEBP_BUILD_WEBPINFO=OFF", "-DWEBP_BUILD_WEBPMUX=OFF", "-DWEBP_BUILD_EXTRAS=OFF"])
        elif name == "libvorbis":
            self.cmake(name, ["-DBUILD_TESTING=OFF"])
        elif name == "libvpx":
            self.configure(name, ["--target=arm64-darwin20-gcc", "--enable-static", "--disable-shared",
                                  "--disable-examples", "--disable-tools", "--disable-unit-tests",
                                  "--enable-vp9-highbitdepth", "--enable-pic"])
        else:
            arguments = ["--enable-static", "--disable-shared"]
            if name == "lame":
                arguments += ["--disable-frontend", "--disable-decoder"]
            self.configure(name, arguments)
        self.complete(name)

    def build_ffmpeg(self):
        for dependency in ("libogg", "libvorbis", "opus", "lame", "libvpx", "webp", "aom"):
            self.build_codec(dependency)
        if not self.completed("ffmpeg"):
            self.configure("ffmpeg", ["--arch=arm64", "--target-os=darwin", "--cc=clang", "--cxx=clang++",
                                      "--disable-autodetect", "--disable-shared", "--enable-static",
                                      "--disable-debug", "--disable-doc", "--disable-network",
                                      "--disable-indevs", "--disable-outdevs", "--enable-indev=lavfi",
                                      "--disable-gpl", "--disable-nonfree", "--enable-zlib",
                                      "--enable-videotoolbox", "--enable-audiotoolbox",
                                      "--enable-libmp3lame", "--enable-libopus", "--enable-libvorbis",
                                      "--enable-libvpx", "--enable-libwebp", "--enable-libaom",
                                      "--pkg-config-flags=--static", f"--extra-cflags=-I{self.prefix / 'include'}",
                                      f"--extra-ldflags=-L{self.prefix / 'lib'}"])
            self.complete("ffmpeg")
        self.copy_executable(self.prefix / "bin/ffmpeg", "ffmpeg")
        self.copy_executable(self.prefix / "bin/ffprobe", "ffprobe")

    def build_ghostscript(self):
        source = self.source("ghostscript")
        if not self.completed("ghostscript"):
            self.configure("ghostscript", ["--without-x", "--disable-cups", "--disable-dbus", "--disable-gtk",
                                           "--disable-fontconfig", "--without-tesseract", "--without-libidn",
                                           "--without-libpaper", "--with-local-zlib", "--with-local-brotli",
                                           "--with-libiconv=no"])
            self.complete("ghostscript")
        self.copy_executable(source / "bin/gs", "gs")
        data = self.output / "Resources/Ghostscript"
        data.mkdir(parents=True, exist_ok=True)
        for folder in ("Resource", "iccprofiles", "lib"):
            shutil.copytree(source / folder, data / folder, dirs_exist_ok=True)

    def build_7zip(self):
        source = self.source("7zip")
        directory = source / "CPP/7zip/Bundles/Alone2"
        if not self.completed("7zip"):
            self.run("7zip", ["make", "-j", self.jobs, "-f", "../../cmpl_mac_arm64.mak",
                               "CFLAGS_BASE2=-mmacosx-version-min=14.0", "CXXFLAGS_BASE2=-mmacosx-version-min=14.0",
                               "LDFLAGS=-mmacosx-version-min=14.0"], directory)
            self.complete("7zip")
        self.copy_executable(directory / "b/m_arm64/7zz", "7zz")

    def copy_executable(self, source, name):
        destination = self.output / "MacOS" / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        destination.chmod(0o755)
        self.verify_binary(destination)

    @staticmethod
    def verify_binary(path):
        architectures = subprocess.check_output(["lipo", "-archs", path], text=True).split()
        if "arm64" not in architectures:
            raise ValueError(f"{path.name} is missing native apple silicon support")
        metadata = subprocess.check_output(["xcrun", "vtool", "-arch", "arm64", "-show-build", path], text=True)
        minimum = next((line.split()[1] for line in metadata.splitlines() if line.strip().startswith("minos ")), None)
        if minimum is None or tuple(map(int, minimum.split("."))) > (14, 0, 0):
            raise ValueError(f"{path.name} requires macOS {minimum}, above the app's supported minimum")
        dependencies = subprocess.check_output(["otool", "-arch", "arm64", "-L", path], text=True)
        for line in dependencies.splitlines()[1:]:
            dependency = line.strip().split(" ", 1)[0]
            if not dependency.startswith(("/usr/lib/", "/System/Library/")):
                raise ValueError(f"{path.name} has an external runtime dependency: {dependency}")

    def install_pandoc(self):
        source = self.source("pandoc")
        self.copy_executable(source / "bin/pandoc", "pandoc")

    def install_libreoffice(self):
        image = self.download("libreoffice")
        mount = self.root / "office-mount"
        mount.mkdir(exist_ok=True)
        self.run("libreoffice", ["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, image])
        try:
            destination = self.output / "Helpers/LibreOffice.app"
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.exists():
                shutil.rmtree(destination)
            self.run("libreoffice", ["ditto", mount / "LibreOffice.app", destination])
        finally:
            self.run("libreoffice", ["hdiutil", "detach", mount])

    def write_manifest(self):
        resources = self.output / "Resources/Engines"
        resources.mkdir(parents=True, exist_ok=True)
        manifest = {**self.lock, "executables": ["MacOS/ffmpeg", "MacOS/ffprobe", "MacOS/pandoc", "MacOS/7zz", "MacOS/gs",
                                               "Helpers/LibreOffice.app/Contents/MacOS/soffice"]}
        for executable in manifest["executables"]:
            if not (self.output / executable).is_file():
                raise ValueError(f"the runtime payload is missing {executable}")
        (resources / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        notices = resources / "Notices"
        notices.mkdir(exist_ok=True)
        # keep upstream license files with each tool, including codec patent grants
        license_names = ("copying", "copyright", "license", "patents", "notice", "authors", "unrarlicense")
        for name in self.lock["components"]:
            if name == "libreoffice":
                target = notices / name
                target.mkdir(exist_ok=True)
                for filename in ("LICENSE", "LICENSE.html", "NOTICE"):
                    shutil.copy2(self.output / "Helpers/LibreOffice.app/Contents/Resources" / filename, target / filename)
                continue
            target = notices / name
            target.mkdir(exist_ok=True)
            if name == "pandoc":
                archive = self.download_spec(name + "-source", self.lock["components"][name]["source"])
                with tarfile.open(archive) as bundle:
                    for member in bundle.getmembers():
                        relative = Path(member.name)
                        if member.isfile() and relative.name.lower().startswith(license_names):
                            destination = target.joinpath(*relative.parts[1:])
                            if not destination.resolve().is_relative_to(target.resolve()):
                                raise ValueError("a notice escapes its directory")
                            destination.parent.mkdir(parents=True, exist_ok=True)
                            with bundle.extractfile(member) as stream:
                                destination.write_bytes(stream.read())
                continue
            source = self.source(name)
            for file in source.rglob("*"):
                if file.is_file() and not file.is_symlink() and file.name.lower().startswith(license_names):
                    destination = target / file.relative_to(source)
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(file, destination)

    def archive_sources(self):
        destination = self.root / "Fileel-Runtime-Sources.tar"
        with tarfile.open(destination, "w") as archive:
            archive.add(LOCK, arcname="Distribution/runtime-lock.json")
            archive.add(Path(__file__), arcname="Scripts/build-runtimes.py")
            archive.add(ROOT / "docs/RUNTIME-DISTRIBUTION.md", arcname="README.md")
            archive.add(ROOT / "docs/RUNTIME-DISTRIBUTION.md", arcname="docs/RUNTIME-DISTRIBUTION.md")
            for name, info in self.lock["components"].items():
                if "revision" in info:
                    checkout = self.source(name)
                    output = self.downloads / f"{name}-{info['version']}.tar.gz"
                    self.run(name, ["git", "-C", checkout, "archive", "--format=tar.gz", f"--prefix={name}-{info['version']}/",
                                    "--output", output, info["revision"]])
                else:
                    output = self.download_spec(name, info.get("source", info))
                archive.add(output, arcname="upstream/" + output.name)
        return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=ROOT / "build/runtime")
    parser.add_argument("--component", choices=("all", "ffmpeg", "ghostscript", "7zip", "pandoc", "libreoffice"), default="all")
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("runtime builds require an apple silicon mac")
    builder = RuntimeBuilder(args.directory)
    components = ("ffmpeg", "ghostscript", "7zip", "pandoc", "libreoffice") if args.component == "all" else (args.component,)
    for component in components:
        print(f"preparing {component}", flush=True)
        getattr(builder, ("install_" if component in ("pandoc", "libreoffice") else "build_") + component)()
    if args.component == "all":
        builder.write_manifest()
        print(f"corresponding sources: {builder.archive_sources()}", flush=True)
    print(f"runtime payload: {builder.output}", flush=True)


if __name__ == "__main__":
    main()
