#!/usr/bin/env python3
"""Register the retained app without letting historical review builds win routing."""

import os
from pathlib import Path
import plistlib
import subprocess
import sys

project = Path(__file__).resolve().parents[1]
outputs = project.parent / "outputs"
retained = (outputs / "native/Timeglow.app").resolve()
lsregister = Path("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
bundle_id = "com.xiaofengchen.Timeglow"


def is_timeglow(path):
    try:
        with (path / "Contents/Info.plist").open("rb") as stream:
            return plistlib.load(stream).get("CFBundleIdentifier") == bundle_id
    except (OSError, ValueError, plistlib.InvalidFileException):
        return False


if not is_timeglow(retained):
    sys.exit(f"Missing or invalid retained development app: {retained}")

candidates = {Path(arg).resolve() for arg in sys.argv[1:]}
for root, directories, _ in os.walk(outputs):
    for name in directories[:]:
        if name.endswith(".app"):
            candidates.add((Path(root) / name).resolve())
            directories.remove(name)
        elif name in {".git", "Index.noindex", "Intermediates.noindex", "ModuleCache.noindex"}:
            directories.remove(name)

for candidate in sorted(candidates):
    if candidate != retained and is_timeglow(candidate):
        # Unregister routing only: retain every archived app and all user data.
        result = subprocess.run([str(lsregister), "-u", str(candidate)], capture_output=True, text=True)
        if result.returncode:
            # kLSApplicationNotFoundErr: archived packages may never have been
            # registered. There is no route to remove in that case.
            if "-10814" in result.stderr + result.stdout:
                continue
            sys.exit(f"Could not unregister {candidate}: {result.stderr or result.stdout}")
        print(f"Unregistered historical build: {candidate}")

subprocess.run([str(lsregister), "-f", str(retained)], check=True)
print(f"Registered retained development app: {retained}")
