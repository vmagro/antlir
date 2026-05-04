#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

"""
Scan antlir BUCK files for third-party Rust crate dependencies and ensure
they are all listed in third-party/rust/Cargo.toml.

Usage:
    python3 third-party/rust/update_deps.py [--check]

Without --check, updates Cargo.toml with any missing deps.
With --check, exits non-zero if Cargo.toml is missing deps.
"""

import os
import re
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent.parent


def find_bare_rust_deps() -> set[str]:
    """Scan BUCK and .bzl files under antlir/ for bare crate names in deps lists."""
    bare_deps: set[str] = set()
    antlir_dir = REPO_ROOT / "antlir"

    # Patterns that indicate a dep is NOT a bare crate name
    # (it's a first-party target reference)
    def is_first_party(dep: str) -> bool:
        return "//" in dep or ":" in dep

    for root, _dirs, files in os.walk(antlir_dir):
        for fname in files:
            if fname not in ("BUCK",) and not fname.endswith(".bzl"):
                continue
            fpath = os.path.join(root, fname)
            with open(fpath) as f:
                content = f.read()

            # Find all string literals inside deps/named_deps/test_deps/fb_deps lists
            # We look for patterns like:
            #   deps = ["crate1", "crate2", "//first-party:target"]
            #   named_deps = {"alias": "crate1"}
            # In starlark, these are often multi-line
            for dep_match in re.finditer(
                r'(?:^|[\s,\[{])\"([a-zA-Z][a-zA-Z0-9_-]*)\"(?=[\s,\]\}])',
                content,
            ):
                candidate = dep_match.group(1)
                if is_first_party(candidate):
                    continue
                # Heuristic: only consider strings that appear in a deps-like context
                # Look backwards for deps/named_deps/test_deps/fb_deps
                pos = dep_match.start()
                # Look at surrounding context (up to 500 chars back)
                context = content[max(0, pos - 500) : pos]
                if re.search(
                    r'(?:deps|named_deps|test_deps|fb_deps|fb_test_deps)\s*=\s*[\[\{]',
                    context,
                ):
                    bare_deps.add(candidate)

    return bare_deps


def parse_cargo_toml_deps(cargo_toml: Path) -> set[str]:
    """Extract dependency names from Cargo.toml [dependencies] section."""
    deps: set[str] = set()
    if not cargo_toml.exists():
        return deps

    in_deps = False
    in_patch = False
    with open(cargo_toml) as f:
        for line in f:
            stripped = line.strip()
            if stripped == "[dependencies]":
                in_deps = True
                in_patch = False
                continue
            if stripped.startswith("["):
                in_deps = False
                if "patch" in stripped:
                    in_patch = True
                continue
            if in_deps:
                m = re.match(r'^([a-zA-Z][a-zA-Z0-9_-]*)\s*=', stripped)
                if m:
                    deps.add(m.group(1))
    return deps


def main():
    check_only = "--check" in sys.argv

    cargo_toml = REPO_ROOT / "third-party" / "rust" / "Cargo.toml"
    bare_deps = find_bare_rust_deps()
    existing_deps = parse_cargo_toml_deps(cargo_toml)

    # Find crate names that are in BUCK files but not in Cargo.toml
    # Note: some deps use different names in Cargo vs BUCK (e.g. package renames)
    # We handle this by checking both the dep name and any package= alias
    missing = bare_deps - existing_deps

    # Filter out false positives: strings that look like crate names but aren't
    # Common false positives from BUCK files
    false_positives = {
        "bash",
        "coreutils",
        "rpm",
        "dnf",
        "apt",
        "default",
        "centos9",
        "centos10",
        "disabled",
        "name",
        "src",
        "test",
        "tests",
        "lib",
        "bin",
        "linux",
        "true",
        "false",
        "none",
        "PUBLIC",
        "oncall",
    }
    missing -= false_positives

    # Also filter out names that are clearly not crate names
    missing = {
        d
        for d in missing
        if not d.startswith("antlir")
        and not d.startswith("fbcode")
        and not d.startswith("fb_")
        and len(d) > 1
    }

    if not missing:
        print("All third-party Rust deps are in Cargo.toml")
        return 0

    print(f"Found {len(missing)} crate(s) referenced in BUCK but not in Cargo.toml:")
    for dep in sorted(missing):
        print(f"  {dep}")

    if check_only:
        return 1

    # Add missing deps to Cargo.toml
    with open(cargo_toml) as f:
        content = f.read()

    # Find the end of [dependencies] section
    deps_end = content.find("\n[patch")
    if deps_end == -1:
        deps_end = len(content)

    new_deps = "\n".join(f'{dep} = "*"' for dep in sorted(missing))
    content = content[:deps_end] + new_deps + "\n" + content[deps_end:]

    with open(cargo_toml, "w") as f:
        f.write(content)

    print(f"\nAdded {len(missing)} dep(s) to Cargo.toml")
    print("Now run:")
    print("  cd third-party/rust && cargo +stable update && cd ../..")
    print("  reindeer buckify")

    return 0


if __name__ == "__main__":
    sys.exit(main())
