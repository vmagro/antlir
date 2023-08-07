/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#![feature(io_error_other)]

use std::collections::BTreeMap;
use std::collections::HashSet;
use std::io::Error;
use std::path::Path;
use std::path::PathBuf;

use antlir2_users::group::EtcGroup;
use antlir2_users::passwd::EtcPasswd;
use anyhow::Context;
use anyhow::Result;
use clap::Parser;
use clap::ValueEnum;
use image_test_lib::get_installed_rpms;
use json_arg::TomlFile;
use similar::TextDiff;
use walkdir::WalkDir;

mod file_entry;
use file_entry::FileEntry;
mod diff;
use diff::FileDiff;
use diff::FileEntryDiff;
use diff::LayerDiff;
mod rpm_entry;
use diff::RpmDiff;
use diff::RpmEntryDiff;
use rpm_entry::RpmEntry;

#[derive(Parser)]
struct Args {
    #[clap(long)]
    /// Parent layer
    parent: PathBuf,
    #[clap(long)]
    /// Child layer
    layer: PathBuf,
    /// Expected diff in TOML format
    #[clap(long)]
    expected: TomlFile<LayerDiff>,
    /// Print the diff instead of running test
    #[clap(long)]
    print: bool,
    /// Exclude entries that start with given prefixes
    #[clap(long)]
    exclude: Vec<String>,
    /// Diff type to generete: file, rpm, or all
    #[clap(long, value_enum, value_parser, default_value_t=DiffType::All)]
    diff_type: DiffType,
}

#[derive(Copy, Clone, PartialEq, Eq, PartialOrd, Ord, ValueEnum)]
enum DiffType {
    File,
    Rpm,
    All,
}

const ALWAYS_EXCLUDE: [&str; 2] = ["var/lib/rpm", "var/lib/dnf"];

fn exclude_entry(entry: &Path, exclude_list: &[String]) -> bool {
    exclude_list
        .iter()
        .any(|e| entry.to_string_lossy().starts_with(e))
}

fn generate_file_diff(args: &Args) -> Result<BTreeMap<PathBuf, FileDiff>> {
    let exclude_list: Vec<String> = args
        .exclude
        .iter()
        .map(|e| e.to_owned())
        .chain(ALWAYS_EXCLUDE.iter().map(|e| e.to_string()))
        .collect();

    let mut entries = BTreeMap::new();
    let mut paths_that_exist_in_layer = HashSet::new();

    let layer_userdb: EtcPasswd = std::fs::read_to_string(args.layer.join("etc/passwd"))
        .and_then(|s| s.parse().map_err(Error::other))
        .unwrap_or_else(|_| Default::default());
    let layer_groupdb: EtcGroup = std::fs::read_to_string(args.layer.join("etc/group"))
        .and_then(|s| s.parse().map_err(Error::other))
        .unwrap_or_else(|_| Default::default());
    let parent_userdb: EtcPasswd = std::fs::read_to_string(args.parent.join("etc/passwd"))
        .and_then(|s| s.parse().map_err(Error::other))
        .unwrap_or_else(|_| Default::default());
    let parent_groupdb: EtcGroup = std::fs::read_to_string(args.parent.join("etc/group"))
        .and_then(|s| s.parse().map_err(Error::other))
        .unwrap_or_else(|_| Default::default());

    for fs_entry in WalkDir::new(&args.layer) {
        let fs_entry = fs_entry?;
        if fs_entry.path() == args.layer {
            continue;
        }
        let relpath = fs_entry
            .path()
            .strip_prefix(&args.layer)
            .expect("this must be relative");

        if exclude_entry(relpath, &exclude_list) {
            continue;
        }

        let parent_path = args.parent.join(relpath);
        let entry = FileEntry::new(fs_entry.path(), &layer_userdb, &layer_groupdb)
            .with_context(|| format!("while building FileEntry for '{}", relpath.display()))?;
        paths_that_exist_in_layer.insert(relpath.to_path_buf());
        // broken symlinks are allowed
        let parent_exists = if fs_entry.path_is_symlink() {
            std::fs::read_link(&parent_path).is_ok()
        } else {
            parent_path.exists()
        };
        if !parent_exists {
            entries.insert(relpath.to_path_buf(), FileDiff::Added(entry));
        } else {
            let parent_entry = FileEntry::new(&parent_path, &parent_userdb, &parent_groupdb)
                .with_context(|| {
                    format!(
                        "while building FileEntry for parent version of '{}",
                        relpath.display(),
                    )
                })?;
            if parent_entry != entry {
                entries.insert(
                    relpath.to_path_buf(),
                    FileDiff::Diff(FileEntryDiff::new(&parent_entry, &entry)),
                );
            }
        }
    }

    for fs_entry in WalkDir::new(&args.parent) {
        let fs_entry = fs_entry?;
        if fs_entry.path() == args.parent {
            continue;
        }
        let relpath = fs_entry
            .path()
            .strip_prefix(&args.parent)
            .expect("this must be relative");

        if exclude_entry(relpath, &exclude_list) {
            continue;
        }

        if !paths_that_exist_in_layer.contains(relpath) {
            let entry = FileEntry::new(fs_entry.path(), &parent_userdb, &parent_groupdb)
                .with_context(|| format!("while building FileEntry for '{}'", relpath.display()))?;
            entries.insert(relpath.to_path_buf(), FileDiff::Removed(entry));
        }
    }

    Ok(entries)
}

fn generate_rpm_diff(args: &Args) -> Result<BTreeMap<String, RpmDiff>> {
    let parent_rpms = get_installed_rpms(args.parent.clone())?;
    let layer_rpms = get_installed_rpms(args.layer.clone())?;
    let mut entries = BTreeMap::new();

    for (name, info) in &layer_rpms {
        let child_entry = RpmEntry::new(info.evra());

        match parent_rpms.get(name) {
            Some(parent_info) => {
                let parent_entry = RpmEntry::new(parent_info.evra());
                if parent_entry != child_entry {
                    entries.insert(
                        name.clone(),
                        RpmDiff::Changed(RpmEntryDiff::new(&parent_entry, &child_entry)),
                    );
                };
            }
            None => {
                entries.insert(
                    name.clone(),
                    RpmDiff::Installed(RpmEntry::new("from_snapshot")),
                );
            }
        }
    }

    for (name, info) in &parent_rpms {
        let parent_entry = RpmEntry::new(info.evra());
        match layer_rpms.get(name) {
            Some(child_info) => {
                let child_entry = RpmEntry::new(child_info.evra());
                if parent_entry != child_entry {
                    entries.insert(
                        name.clone(),
                        RpmDiff::Changed(RpmEntryDiff::new(&parent_entry, &child_entry)),
                    );
                };
            }
            None => {
                entries.insert(
                    name.clone(),
                    RpmDiff::Removed(RpmEntry::new("from_snapshot")),
                );
            }
        }
    }

    Ok(entries)
}

fn main() -> Result<()> {
    let args = Args::parse();

    let (file_diff, rpm_diff) = match args.diff_type {
        DiffType::File => (Some(generate_file_diff(&args)?), None),
        DiffType::Rpm => (None, Some(generate_rpm_diff(&args)?)),
        DiffType::All => (
            Some(generate_file_diff(&args)?),
            Some(generate_rpm_diff(&args)?),
        ),
    };

    let diff = LayerDiff {
        file: file_diff,
        rpm: rpm_diff,
    };

    if args.print {
        println!(
            "{}",
            toml::to_string_pretty(&diff).context("while serializing")?
        );

        return Ok(());
    }

    if &diff != args.expected.as_inner() {
        println!(
            "{}",
            TextDiff::from_lines(
                &toml::to_string_pretty(args.expected.as_inner())
                    .context("while (re)serializing expected")?,
                &toml::to_string_pretty(&diff)
                    .with_context(|| format!("while serializing actual diff: {diff:#?}"))?,
            )
            .unified_diff()
            .context_radius(3)
            .header("expected", "actual")
        );
        anyhow::bail!("actual diff did not match expected diff");
    }

    Ok(())
}
