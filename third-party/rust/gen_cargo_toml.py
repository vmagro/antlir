#!/usr/bin/env python3
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

"""
Reverse-engineer Cargo.toml from the existing reindeer-generated BUCK file.

This script parses the third-party/rust/BUCK file and produces a Cargo.toml
that, when used with `reindeer buckify`, will regenerate an equivalent BUCK.

Usage:
    python3 third-party/rust/gen_cargo_toml.py > third-party/rust/Cargo.toml
"""

import re
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent.parent
BUCK_FILE = REPO_ROOT / "third-party" / "rust" / "BUCK"


def parse_starlark_list(text: str) -> list[str]:
    """Extract string items from a starlark list literal."""
    return re.findall(r'"([^"]*)"', text)


def parse_buck_file(content: str):
    """Parse the BUCK file into structured data."""

    # 1. Parse git_fetch entries
    git_fetches = {}
    for m in re.finditer(
        r'git_fetch\(\s*name = "([^"]+)".*?repo = "([^"]+)".*?rev = "([^"]+)"',
        content,
        re.DOTALL,
    ):
        git_fetches[m.group(1)] = {
            "repo": m.group(2),
            "rev": m.group(3),
        }

    # 2. Parse http_archive entries to get real crate names from URLs
    http_archives = {}
    for m in re.finditer(
        r'http_archive\(\s*name = "([^"]+)\.crate".*?'
        r'urls = \["https://static\.crates\.io/crates/([^/]+)/([^/]+)/download"\]',
        content,
        re.DOTALL,
    ):
        http_archives[m.group(1)] = {
            "real_name": m.group(2),
            "real_version": m.group(3),
        }

    # 3. Parse cargo.rust_library blocks carefully (block by block)
    cargo_libs = {}
    # Split content at each cargo.rust_library( or cargo.rust_binary(
    # but also at http_archive( and alias( and git_fetch( to delimit blocks
    block_starts = []
    for m in re.finditer(r'^(cargo\.rust_library|cargo\.rust_binary)\(', content, re.MULTILINE):
        block_starts.append((m.start(), m.group(1)))

    for i, (start, kind) in enumerate(block_starts):
        # Find end of this block - next top-level statement
        end = len(content)
        # Find the matching closing paren by counting parens
        depth = 0
        in_str = False
        j = start
        while j < len(content):
            c = content[j]
            if c == '"' and (j == 0 or content[j-1] != '\\'):
                in_str = not in_str
            elif not in_str:
                if c == '(':
                    depth += 1
                elif c == ')':
                    depth -= 1
                    if depth == 0:
                        end = j + 1
                        break
            j += 1

        block = content[start:end]

        name_m = re.search(r'name = "([^"]+)"', block)
        if not name_m:
            continue
        name = name_m.group(1)

        crate_m = re.search(r'\bcrate = "([^"]+)"', block)
        crate_name = crate_m.group(1) if crate_m else None

        srcs_m = re.search(r'srcs = \["([^"]+)"\]', block)
        srcs = srcs_m.group(1) if srcs_m else None

        # Extract the full version from the .crate source name
        # e.g. srcs = [":addr2line-0.24.2.crate"] -> "0.24.2"
        full_version = None
        if srcs and srcs.endswith(".crate"):
            crate_name_from_src = srcs.lstrip(":").removesuffix(".crate")
            full_version = extract_version(crate_name_from_src)

        feat_m = re.search(r'\bfeatures = \[(.*?)\]', block, re.DOTALL)
        features = parse_starlark_list(feat_m.group(1)) if feat_m else []

        is_git = srcs and ".git" in srcs

        cargo_libs[name] = {
            "kind": kind,
            "crate": crate_name,
            "srcs": srcs,
            "full_version": full_version,
            "features": features,
            "is_git": is_git,
        }

    # 4. Parse alias entries
    aliases = {}
    for m in re.finditer(
        r'alias\(\s*name = "([^"]+)",\s*actual = ":([^"]+)",', content
    ):
        aliases[m.group(1)] = m.group(2)

    return git_fetches, http_archives, cargo_libs, aliases


def extract_version(versioned_name: str) -> str | None:
    """Extract version from a versioned crate name like 'anyhow-1.0.98'."""
    for i in range(len(versioned_name) - 1, -1, -1):
        if versioned_name[i] == '-':
            candidate = versioned_name[i + 1:]
            if re.match(r'^\d+\.\d+', candidate):
                return candidate
    return None


def main():
    content = BUCK_FILE.read_text()
    git_fetches, http_archives, cargo_libs, aliases = parse_buck_file(content)

    # Identify git-sourced crates
    git_crates = {}  # versioned_name -> (repo, rev)
    for name, info in cargo_libs.items():
        if info["is_git"]:
            srcs = info["srcs"]
            git_name = re.match(r':([^[]+\.git)', srcs)
            if git_name and git_name.group(1) in git_fetches:
                gf = git_fetches[git_name.group(1)]
                git_crates[name] = gf

    # Build the Cargo.toml
    lines = []
    lines.append("[workspace]")
    lines.append("")
    lines.append("[package]")
    lines.append('name = "rust-third-party"')
    lines.append('version = "0.0.0"')
    lines.append('edition = "2021"')
    lines.append("publish = false")
    lines.append("")
    lines.append("[[bin]]")
    lines.append('name = "top"')
    lines.append('path = "top/main.rs"')
    lines.append("")
    lines.append("[dependencies]")

    git_patch_entries = {}  # unused, kept for reference

    for alias_name, versioned in sorted(aliases.items()):
        lib_info = cargo_libs.get(versioned)
        if not lib_info:
            continue

        features = lib_info["features"]
        non_default = sorted([f for f in features if f != "default"])
        has_default = "default" in features

        if versioned in git_crates:
            # Git-sourced crate
            gf = git_crates[versioned]
            ver = lib_info.get("full_version") or extract_version(versioned)
            if not ver:
                continue

            parts = [f'version = "={ver}"']
            if not has_default and features is not None:
                parts.append("default-features = false")
            if non_default:
                feat_str = ", ".join(f'"{f}"' for f in non_default)
                parts.append(f"features = [{feat_str}]")

            lines.append(f'{alias_name} = {{ {", ".join(parts)} }}')

            real_crate = lib_info["crate"] or alias_name
            git_patch_entries[real_crate] = gf
            continue

        # http_archive crate - get real name and version
        # Prefer full version from the cargo.rust_library's source
        if lib_info.get("full_version"):
            real_ver = lib_info["full_version"]
            # Get real crate name from http_archive URL if available
            src_name = lib_info["srcs"].lstrip(":").removesuffix(".crate") if lib_info.get("srcs") else None
            if src_name and src_name in http_archives:
                real_name = http_archives[src_name]["real_name"]
            else:
                real_name = lib_info.get("crate") or alias_name
        elif versioned in http_archives:
            real_name = http_archives[versioned]["real_name"]
            real_ver = http_archives[versioned]["real_version"]
        else:
            real_ver = extract_version(versioned)
            real_name = lib_info.get("crate") or alias_name
            if not real_ver:
                continue

        parts = [f'version = "={real_ver}"']

        # If alias name differs from real crate name, add package rename
        if real_name != alias_name:
            parts.insert(0, f'package = "{real_name}"')

        if not has_default and features is not None:
            parts.append("default-features = false")
        if non_default:
            feat_str = ", ".join(f'"{f}"' for f in non_default)
            parts.append(f"features = [{feat_str}]")

        lines.append(f'{alias_name} = {{ {", ".join(parts)} }}')

    lines.append("")
    lines.append("[patch.crates-io]")

    # Group patches by repo - include ALL git-sourced crates, not just aliased ones
    by_repo: dict[tuple, list] = {}
    for versioned_name, gf in sorted(git_crates.items()):
        lib_info = cargo_libs.get(versioned_name)
        if not lib_info:
            continue
        real_crate = lib_info.get("crate") or versioned_name
        key = (gf["repo"], gf["rev"])
        if key not in by_repo:
            by_repo[key] = []
        by_repo[key].append(real_crate)

    for (repo, rev), crates in sorted(by_repo.items()):
        for c in sorted(crates):
            lines.append(f'{c} = {{ git = "{repo}", rev = "{rev}" }}')

    print("\n".join(lines))


if __name__ == "__main__":
    main()
