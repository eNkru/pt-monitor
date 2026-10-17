#!/usr/bin/env python3
"""Verifies every *.lproj/Localizable.strings pair carries the same key set.

Runs as part of scripts/build-app.sh (before the bundle is signed) so a
translation that lags the English strings fails the build instead of silently
rendering English key text in the other language.

Usage: check-localization.py <resources-dir>
"""

import glob
import json
import subprocess
import sys
from pathlib import Path


def load_keys(path: Path) -> set:
    # .strings files are old-style plists. plutil (ships with macOS) converts
    # them to JSON on stdout; Python's plistlib is stricter than NeXTSTEP
    # syntax about unquoted non-ASCII strings, so don't use it here.
    result = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(path)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise ValueError(result.stderr.strip() or "plutil failed")
    return set(json.loads(result.stdout).keys())


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <resources-dir>", file=sys.stderr)
        return 2

    resources = Path(sys.argv[1])
    tables = sorted(glob.glob(str(resources / "*.lproj" / "Localizable.strings")))
    if len(tables) < 2:
        print(f"error: expected at least 2 Localizable.strings under {resources}, found {len(tables)}",
              file=sys.stderr)
        return 1

    keysets = {}
    for table in tables:
        language = Path(table).parent.name.removesuffix(".lproj")
        try:
            keysets[language] = load_keys(Path(table))
        except Exception as exc:  # unparseable .strings
            print(f"error: cannot parse {table}: {exc}", file=sys.stderr)
            return 1

    reference_language, reference_keys = next(iter(keysets.items()))
    ok = True
    for language, keys in keysets.items():
        missing = reference_keys - keys
        extra = keys - reference_keys
        if missing:
            ok = False
            print(f"error: {language} is missing keys present in {reference_language}: "
                  f"{sorted(missing)}", file=sys.stderr)
        if extra:
            ok = False
            print(f"error: {language} has keys absent from {reference_language}: "
                  f"{sorted(extra)}", file=sys.stderr)
    if ok:
        print(f"==> localization parity: {len(keysets)} languages, {len(reference_keys)} keys each")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
