#!/usr/bin/env python3
"""Build, sign, and optionally install the macOS application bundle."""

import argparse
import os
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
APP_NAME = "菜单改键.app"
IDENTIFIER = "io.github.imkkdev.menu-rebind"
VERSION = "0.1.1"


def build_icon(work_directory, destination):
    source = PROJECT / "Assets" / "AppIcon.png"
    iconset = work_directory / "AppIcon.iconset"
    iconset.mkdir()
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            suffix = "" if scale == 1 else "@2x"
            image = iconset / f"icon_{points}x{points}{suffix}.png"
            pixels = str(points * scale)
            subprocess.run([
                "sips", "-z", pixels, pixels, str(source), "--out", str(image)
            ], stdout=subprocess.DEVNULL, check=True)
    subprocess.run(["iconutil", "-c", "icns", "-o", str(destination), str(iconset)], check=True)


def replace_bundle(staged, destination):
    backup = staged.parent / "previous.app"
    if destination.is_symlink():
        raise SystemExit(f"拒绝替换符号链接 {destination}")
    if destination.exists():
        info = destination / "Contents" / "Info.plist"
        if not info.is_file() or plistlib.loads(info.read_bytes()).get("CFBundleIdentifier") != IDENTIFIER:
            raise SystemExit(f"目标路径已有另一个应用 {destination}")
        destination.rename(backup)
    try:
        staged.rename(destination)
    except OSError:
        if backup.exists():
            backup.rename(destination)
        raise


def package(executable, output_directory):
    output_directory.mkdir(parents=True, exist_ok=True)
    destination = output_directory / APP_NAME
    with tempfile.TemporaryDirectory(prefix=".menu-rebind-", dir=output_directory) as temporary:
        staged = Path(temporary) / APP_NAME
        contents = staged / "Contents"
        binary_directory = contents / "MacOS"
        binary_directory.mkdir(parents=True)
        resources = contents / "Resources"
        resources.mkdir()
        build_icon(Path(temporary), resources / "AppIcon.icns")
        shutil.copy2(executable, binary_directory / "MenuRebind")
        info = {
            "CFBundleDevelopmentRegion": "zh_CN",
            "CFBundleDisplayName": "菜单改键",
            "CFBundleExecutable": "MenuRebind",
            "CFBundleIconFile": "AppIcon",
            "CFBundleIdentifier": IDENTIFIER,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "Menu Rebind",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": VERSION,
            "CFBundleVersion": "2",
            "LSMinimumSystemVersion": "14.0",
            "NSHighResolutionCapable": True,
        }
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        subprocess.run(["codesign", "--force", "--sign", "-", str(staged)], check=True)
        subprocess.run(["codesign", "--verify", "--strict", str(staged)], check=True)
        replace_bundle(staged, destination)
    return destination


def install(bundle, directory):
    directory.mkdir(parents=True, exist_ok=True)
    destination = directory / APP_NAME
    with tempfile.TemporaryDirectory(prefix=".menu-rebind-", dir=directory) as temporary:
        staged = Path(temporary) / APP_NAME
        subprocess.run(["ditto", str(bundle), str(staged)], check=True)
        subprocess.run(["codesign", "--verify", "--strict", str(staged)], check=True)
        replace_bundle(staged, destination)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--install", nargs="?", const="", metavar="DIRECTORY",
        help="安装到指定目录。省略目录时优先使用 /Applications",
    )
    options = parser.parse_args()

    build = ["xcrun", "swift", "build", "--package-path", str(PROJECT), "-c", "release"]
    subprocess.run(build, check=True)
    binary_dir = Path(subprocess.check_output([*build, "--show-bin-path"], text=True).strip())
    bundle = package(binary_dir / "MenuRebind", PROJECT / "dist")
    print(f"已打包 {bundle}")
    if options.install is not None:
        applications = Path("/Applications")
        if options.install:
            applications = Path(options.install).expanduser().resolve()
        elif not os.access(applications, os.W_OK):
            applications = Path.home() / "Applications"
        print(f"已安装 {install(bundle, applications)}")


if __name__ == "__main__":
    main()
