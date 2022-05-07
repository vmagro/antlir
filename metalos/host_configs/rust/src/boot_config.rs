/*
 * Copyright (c) Meta Platforms, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use std::path::PathBuf;

use crate::packages;
use thrift_wrapper::ThriftWrapper;

#[derive(Debug, Clone, PartialEq, Eq, ThriftWrapper)]
#[thrift(metalos_thrift_host_configs::boot_config::BootConfig)]
pub struct BootConfig {
    #[cfg(facebook)]
    pub deployment_specific: crate::facebook::deployment_specific::DeploymentBootConfig,
    pub rootfs: packages::Rootfs,
    pub kernel: Kernel,
    pub initrd: packages::Initrd,
}

#[derive(Debug, Clone, PartialEq, Eq, ThriftWrapper)]
#[thrift(metalos_thrift_host_configs::boot_config::Kernel)]
pub struct Kernel {
    pub pkg: packages::Kernel,
    pub cmdline: String,
}

impl Kernel {
    /// Path to the kernel vmlinuz
    pub fn vmlinuz(&self) -> Option<PathBuf> {
        self.pkg.file_in_image("vmlinuz")
    }

    /// Path to the disk boot modules cpio archive
    pub fn disk_boot_modules(&self) -> Option<PathBuf> {
        self.pkg.file_in_image("disk-boot-modules.cpio.gz")
    }

    /// Path to the full directory of modules
    pub fn modules(&self) -> Option<PathBuf> {
        self.pkg.file_in_image("modules")
    }
}
