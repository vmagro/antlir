/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use std::fmt::Debug;
use std::io::ErrorKind;
use std::os::fd::AsRawFd;
use std::path::Path;
use std::path::PathBuf;
use std::process::Command;

use nix::dir::Dir;
use nix::errno::Errno;
use nix::fcntl::flock;
use nix::fcntl::FlockArg;
use nix::fcntl::OFlag;
use nix::sys::stat::Mode;
use tracing::trace;
use uuid::Uuid;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error("failed to add redirect: {error}")]
    AddRedirect { error: String },
    #[error("failed to create working volume")]
    CreateWorkingVolume(std::io::Error),
    #[error("failed to check eden presence")]
    CheckEden(std::io::Error),
}

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, Clone)]
pub struct WorkingVolume {
    path: PathBuf,
}

impl WorkingVolume {
    /// Ensure this [WorkingVolume] exists and is set up correctly.
    pub fn ensure(path: PathBuf) -> Result<Self> {
        // If we're on Eden, create a new redirection
        // https://www.internalfb.com/intern/wiki/EdenFS/detecting-an-eden-mount/#on-linux-and-macos
        match Dir::open(".eden", OFlag::O_RDONLY, Mode::empty()) {
            Ok(dir) => {
                // There seems to be some racy behavior with eden adding
                // redirects, take an exclusive lock before adding
                flock(dir.as_raw_fd(), FlockArg::LockExclusive).map_err(std::io::Error::from)?;
                if !path.exists() {
                    let res = Command::new("eden")
                        .env("EDENFSCTL_ONLY_RUST", "1")
                        .arg("redirect")
                        .arg("add")
                        .arg(&path)
                        .arg("bind")
                        .output()
                        .map_err(|e| Error::AddRedirect {
                            error: e.to_string(),
                        })?;
                    if !res.status.success() {
                        return Err(Error::AddRedirect {
                            error: String::from_utf8_lossy(&res.stderr).into_owned(),
                        });
                    }
                }
                Ok(Self { path })
            }
            Err(e) => match e {
                Errno::ENOENT => {
                    trace!("no .eden: {e:?}");
                    if let Err(e) = std::fs::create_dir(&path) {
                        match e.kind() {
                            ErrorKind::AlreadyExists => Ok(Self { path }),
                            _ => Err(Error::CreateWorkingVolume(e)),
                        }
                    } else {
                        Ok(Self { path })
                    }
                }
                _ => Err(Error::CheckEden(std::io::Error::from(e))),
            },
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Provide a new (non-existent) path for an image build to put its result
    /// into.
    pub fn allocate_new_path(&self) -> Result<PathBuf> {
        Ok(self.path.join(Uuid::new_v4().simple().to_string()))
    }
}
