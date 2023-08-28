/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use std::path::Path;
use std::path::PathBuf;
use std::process::Command;

use anyhow::anyhow;
use anyhow::Context;
use anyhow::Result;
use clap::Parser;
use json_arg::JsonFile;
use tracing_subscriber::prelude::*;

mod btrfs;
mod cpio;
mod gpt;
mod rpm;
mod sendstream;
mod spec;
mod squashfs;
mod tar;
mod vfat;
use spec::Spec;

pub(crate) trait PackageFormat {
    fn build(&self, out: &Path) -> Result<()>;
}

#[derive(Parser, Debug)]
/// Package an image layer into a file
pub(crate) struct PackageArgs {
    #[clap(long)]
    /// Specifications for the packaging
    spec: JsonFile<Spec>,
    #[clap(long)]
    /// Path to output the image
    out: PathBuf,
}

pub(crate) fn run_cmd(command: &mut Command) -> Result<std::process::Output> {
    let output = command.output().context("Failed to run command")?;

    match output.status.success() {
        true => Ok(output),
        false => Err(anyhow!("failed to run command {:?}: {:?}", command, output)),
    }
}

fn main() -> Result<()> {
    let args = PackageArgs::parse();

    tracing_subscriber::registry()
        .with(
            tracing_subscriber::fmt::Layer::default()
                .event_format(
                    tracing_glog::Glog::default()
                        .with_span_context(true)
                        .with_timer(tracing_glog::LocalTime::default()),
                )
                .fmt_fields(tracing_glog::GlogFields::default()),
        )
        .with(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    match args.spec.into_inner() {
        Spec::Btrfs(p) => p.build(&args.out),
        Spec::Cpio(p) => p.build(&args.out),
        Spec::Gpt(p) => p.build(&args.out),
        Spec::Rpm(p) => p.build(&args.out),
        Spec::Sendstream(p) => p.build(&args.out),
        Spec::Squashfs(p) => p.build(&args.out),
        Spec::Tar(p) => p.build(&args.out),
        Spec::Vfat(p) => p.build(&args.out),
    }
}