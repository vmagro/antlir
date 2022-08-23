/*
 * Copyright (c) Meta Platforms, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use std::path::PathBuf;

use systemd::UnitName;
use thrift_wrapper::ThriftWrapper;

use crate::packages;

#[derive(Debug, Clone, PartialEq, Eq, ThriftWrapper)]
#[thrift(metalos_thrift_host_configs::runtime_config::RuntimeConfig)]
pub struct RuntimeConfig {
    #[cfg(facebook)]
    pub deployment_specific: crate::facebook::deployment_specific::DeploymentRuntimeConfig,
    pub services: Vec<Service>,
}

#[derive(Debug, Copy, Clone, PartialEq, PartialOrd, Ord, Eq, ThriftWrapper)]
#[thrift(metalos_thrift_host_configs::runtime_config::ServiceType)]
pub enum ServiceType {
    NATIVE,
    OS,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, ThriftWrapper)]
#[thrift(metalos_thrift_host_configs::runtime_config::Service)]
pub struct Service {
    pub svc: packages::Service,
    pub config_generator: Option<packages::ServiceConfigGenerator>,
    pub svc_type: Option<ServiceType>,
}

impl Service {
    pub fn name(&self) -> &str {
        &self.svc.name
    }

    /// Path to metalos metadata dir
    pub fn metalos_dir(&self) -> Option<PathBuf> {
        self.svc.file_in_image("metalos")
    }

    /// Systemd unit name
    pub fn unit_name(&self) -> UnitName {
        format!("{}.service", self.svc.name).into()
    }

    pub fn unit_file(&self) -> Option<PathBuf> {
        let path = self.metalos_dir().map(|d| d.join(self.unit_name()))?;
        match path.exists() {
            true => Some(path),
            false => None,
        }
    }
}
