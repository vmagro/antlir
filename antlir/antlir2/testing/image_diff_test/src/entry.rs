/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::fmt::Display;
use std::hash::Hasher;
use std::os::unix::fs::FileTypeExt;
use std::os::unix::prelude::MetadataExt;
use std::path::Path;
use std::str::FromStr;

use antlir2_mode::Mode;
use antlir2_users::group::EtcGroup;
use antlir2_users::passwd::EtcPasswd;
use anyhow::Context;
use anyhow::Result;
use serde::Deserialize;
use serde::Serialize;
use serde_with::serde_as;
use serde_with::DisplayFromStr;
use twox_hash::XxHash64;

#[serde_as]
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub(crate) struct Entry {
    #[serde_as(as = "DisplayFromStr")]
    pub(crate) mode: Mode,
    #[serde_as(as = "DisplayFromStr")]
    pub(crate) file_type: FileType,
    pub(crate) user: String,
    pub(crate) group: String,
    #[serde(default)]
    pub(crate) text: Option<String>,
    #[serde(default)]
    pub(crate) content_hash: Option<u64>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub(crate) xattrs: BTreeMap<OsString, Vec<u8>>,
}

impl Entry {
    pub fn new(path: &Path, users: &EtcPasswd, groups: &EtcGroup) -> Result<Self> {
        let meta = std::fs::symlink_metadata(path).context("while statting file")?;
        let mode = Mode::from(meta.permissions());
        if meta.is_symlink() {
            let target = std::fs::read_link(path).context("while reading symlink target")?;
            // symlinks do not have xattrs or many other properties of a file,
            // so we just put the symlink in as the text content
            return Ok(Self {
                mode,
                file_type: FileType::from(meta.file_type()),
                user: users
                    .get_user_by_id(meta.uid().into())
                    .with_context(|| format!("no such uid {}", meta.uid()))?
                    .name
                    .to_string(),
                group: groups
                    .get_group_by_id(meta.gid().into())
                    .with_context(|| format!("no such gid {}", meta.gid()))?
                    .name
                    .to_string(),
                text: Some(
                    target
                        .to_str()
                        .context("symlink target is not utf8")?
                        .to_owned(),
                ),
                content_hash: None,
                xattrs: Default::default(),
            });
        }
        let (text, content_hash) = if meta.is_file() {
            let contents = std::fs::read(path).context("while reading file")?;
            let mut hasher = XxHash64::with_seed(0);
            hasher.write(&contents);
            (String::from_utf8(contents).ok(), hasher.finish())
        } else {
            (None, 0)
        };
        let xattrs = xattr::list(path)
            .context("while listing xattrs")?
            .filter_map(|name| {
                xattr::get(path, &name)
                    .context("while reading xattr")
                    .map(|value| value.map(|value| (name, value)))
                    .transpose()
            })
            .collect::<Result<_>>()?;
        Ok(Self {
            mode,
            user: users
                .get_user_by_id(meta.uid().into())
                .with_context(|| format!("no such uid {}", meta.uid()))?
                .name
                .to_string(),
            group: groups
                .get_group_by_id(meta.gid().into())
                .with_context(|| format!("no such gid {}", meta.gid()))?
                .name
                .to_string(),
            file_type: FileType::from(meta.file_type()),
            xattrs,
            content_hash: if text.is_none() {
                Some(content_hash)
            } else {
                None
            },
            text,
        })
    }
}

#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub enum FileType {
    BlockDevice,
    CharacterDevice,
    Directory,
    Fifo,
    RegularFile,
    Socket,
    Symlink,
}

impl From<std::fs::FileType> for FileType {
    fn from(f: std::fs::FileType) -> Self {
        if f.is_block_device() {
            // technically a device could be (and always? is) both a block and
            // character device, but we want to report it as a block device here
            Self::BlockDevice
        } else if f.is_char_device() {
            Self::CharacterDevice
        } else if f.is_dir() {
            Self::Directory
        } else if f.is_fifo() {
            Self::Fifo
        } else if f.is_socket() {
            Self::Socket
        } else if f.is_symlink() {
            Self::Symlink
        } else if f.is_file() {
            Self::RegularFile
        } else {
            unreachable!("everything should fall under one of those")
        }
    }
}

impl Display for FileType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::BlockDevice => "block-device",
            Self::CharacterDevice => "character-device",
            Self::Directory => "directory",
            Self::Fifo => "fifo",
            Self::RegularFile => "regular-file",
            Self::Socket => "socket",
            Self::Symlink => "symlink",
        })
    }
}

impl FromStr for FileType {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "block-device" => Ok(Self::BlockDevice),
            "character-device" => Ok(Self::CharacterDevice),
            "directory" => Ok(Self::Directory),
            "fifo" => Ok(Self::Fifo),
            "regular-file" => Ok(Self::RegularFile),
            "socket" => Ok(Self::Socket),
            "symlink" => Ok(Self::Symlink),
            _ => Err(format!("unknown filetype: '{s}'")),
        }
    }
}