#!/usr/bin/env python3

import argparse
import json
import os
import re
import sys
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen


RELEASES_URL = "https://www.kernel.org/releases.json"
VERSION_PATTERN = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
SHA_PATTERN = re.compile(r"^([0-9a-f]{64})\s+\*?([A-Za-z0-9._+-]+)$")


def fetch(url):
    request = Request(url, headers={"User-Agent": "athena-kernel-lts-update"})
    with urlopen(request, timeout=30) as response:
        return response.read().decode("utf-8")


def version_key(version):
    return tuple(int(part) for part in version.split("."))


def latest_lts_release(releases):
    versions = [
        release["version"]
        for release in releases
        if release.get("moniker") == "longterm"
        and release.get("iseol") is False
        and isinstance(release.get("version"), str)
        and VERSION_PATTERN.fullmatch(release["version"])
    ]
    if not versions:
        raise ValueError("kernel.org did not list an active longterm release")
    return max(versions, key=version_key)


def checksum_for(checksum_file, filename):
    matches = []
    for line in checksum_file.splitlines():
        match = SHA_PATTERN.fullmatch(line.strip())
        if match and match.group(2) == filename:
            matches.append(match.group(1))
    if len(matches) != 1:
        raise ValueError(
            f"expected one SHA-256 entry for {filename}, found {len(matches)}"
        )
    return matches[0]


def update_pins(build_script, version, checksum):
    if not VERSION_PATTERN.fullmatch(version):
        raise ValueError(f"invalid kernel version: {version}")
    if not re.fullmatch(r"[0-9a-f]{64}", checksum):
        raise ValueError("invalid kernel SHA-256")

    version_lines = re.findall(r"(?m)^KVER=([0-9.]+)$", build_script)
    checksum_lines = re.findall(r"(?m)^KSHA256=([0-9a-f]{64})$", build_script)
    if len(version_lines) != 1 or len(checksum_lines) != 1:
        raise ValueError("expected exactly one KVER and KSHA256 pin in build.sh")

    current = version_lines[0]
    if version_key(version) <= version_key(current):
        return build_script, current, False

    updated = re.sub(r"(?m)^KVER=[0-9.]+$", f"KVER={version}", build_script)
    updated = re.sub(r"(?m)^KSHA256=[0-9a-f]{64}$", f"KSHA256={checksum}", updated)
    return updated, current, True


def write_outputs(values):
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as stream:
            for key, value in values.items():
                stream.write(f"{key}={value}\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    build_path = root / "build.sh"
    build_script = build_path.read_text(encoding="utf-8")
    current_match = re.search(r"(?m)^KVER=([0-9.]+)$", build_script)
    if not current_match:
        raise ValueError("could not read KVER from build.sh")

    release_data = json.loads(fetch(RELEASES_URL))
    version = latest_lts_release(release_data.get("releases", []))
    current = current_match.group(1)
    if version_key(version) <= version_key(current):
        print(f"Kernel pin is current: {current}; latest active LTS is {version}")
        write_outputs({"changed": "false", "version": version})
        return 0

    major = version.split(".", 1)[0]
    checksums_url = f"https://cdn.kernel.org/pub/linux/kernel/v{major}.x/sha256sums.asc"
    checksums = fetch(checksums_url)
    filename = f"linux-{version}.tar.xz"
    checksum = checksum_for(checksums, filename)
    updated, _, changed = update_pins(build_script, version, checksum)
    if not changed:
        print(f"Kernel pin is already current: {version}")
        write_outputs({"changed": "false", "version": version})
        return 0

    if not args.dry_run:
        build_path.write_text(updated, encoding="utf-8")
    print(f"Kernel update available: {current} to {version}")
    if args.dry_run:
        print("Dry run; build.sh was not changed")
    print(f"SHA-256: {checksum}")
    write_outputs({"changed": "true", "version": version, "sha256": checksum})
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, URLError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"kernel LTS update failed: {error}", file=sys.stderr)
        raise SystemExit(1)
