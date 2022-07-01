/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use std::collections::BTreeMap;

use anyhow::Context;
use anyhow::Result;
use gpt::disk::LogicalBlockSize;
use gpt::header::read_header_from_arbitrary_device;
use gpt::partition::file_read_partitions;
use gpt::partition::Partition;

use metalos_disk::DiskDevPath;
use metalos_disk::ReadDisk;
use metalos_disk::MEGABYTE;

#[derive(Debug)]
pub struct PartitionDelta {
    pub partition_num: u32,
    pub old_size: u64,
    pub new_size: u64,
    pub new_last_lb: u64,
}

pub fn expand_last_partition(device: &DiskDevPath) -> Result<PartitionDelta> {
    // First we read the current device GPT header and it's partitions.
    // We can't use the top level GptConfig logic from the crate because that
    // assumes that the backup is in the correct place which it won't necessarily be
    // because we have just dd'd the image to this disk.
    let mut disk_file = device.open_ro_file()?;

    let (lb_size, primary_header) =
        match read_header_from_arbitrary_device(&mut disk_file, LogicalBlockSize::Lb512) {
            Ok(header) => Ok((LogicalBlockSize::Lb512, header)),
            Err(e) => {
                match read_header_from_arbitrary_device(&mut disk_file, LogicalBlockSize::Lb4096) {
                    Ok(header) => Ok((LogicalBlockSize::Lb4096, header)),
                    Err(_) => Err(e),
                }
            }
        }
        .context("Failed to read the primary header from disk")?;

    let original_partitions = file_read_partitions(&mut disk_file, &primary_header, lb_size)
        .context("failed to read partitions from disk_device file")?;

    // Now we must find the end of the disk that we are allowed to expand up to and transform our
    // partitions so that the last one goes all the way to the end
    let (new_partitions, delta) = transform_partitions(
        original_partitions.clone(),
        lb_size,
        get_last_usable_lb(&disk_file, lb_size)
            .context("failed to find last usable block of device")?,
    )
    .context("failed to transform partitions")?;

    // Finally in order to get the final setup valid we must write a whole new GPT so that the backup
    // will be in the right place.
    let mut new_gpt_table = gpt::GptConfig::new()
        .writable(true)
        .initialized(false)
        .logical_block_size(lb_size)
        .open(&device.0)
        .context("failed to load gpt table")?;

    new_gpt_table
        .update_guid(Some(primary_header.disk_guid))
        .context("failed to copy over guid")?;

    new_gpt_table
        .update_partitions(new_partitions)
        .context("failed to add updated partitions to gpt_table")?;

    let device = new_gpt_table
        .write()
        .context("failed to write updated table")?;

    // Now we double check that all wen't well by trying to load back the GPT using the high level
    // API that enforces the backups are valid.
    gpt::GptConfig::new()
        .writable(false)
        .initialized(true)
        .open_from_device(device)
        .context("failed to read GPT after resize")?;

    Ok(delta)
}

fn transform_partitions(
    mut partitions: BTreeMap<u32, Partition>,
    lb_size: LogicalBlockSize,
    last_usable_lba: u64,
) -> Result<(BTreeMap<u32, Partition>, PartitionDelta)> {
    let (last_partition_id, mut last_partition) = partitions
        .iter_mut()
        .max_by_key(|(_, p)| p.last_lba)
        .context("Failed to find the last partition")?;

    let original_last_lba = last_partition.last_lba;
    last_partition.last_lba = last_usable_lba;

    let lb_size_bytes: u64 = lb_size.into();
    let delta = PartitionDelta {
        partition_num: *last_partition_id,
        old_size: (original_last_lba - last_partition.first_lba) * lb_size_bytes,
        new_size: (last_partition.last_lba - last_partition.first_lba) * lb_size_bytes,
        new_last_lb: last_partition.last_lba,
    };
    Ok((partitions, delta))
}

fn get_last_usable_lb<D: ReadDisk>(disk_file: &D, lb_size: LogicalBlockSize) -> Result<u64> {
    let lb_size_bytes: u64 = lb_size.clone().into();
    let disk_size = disk_file
        .get_block_device_size()
        .context("Failed to find disk size")?;

    // I am not sure why this is the forumla. I copied it from D26917298
    // I believe it has something to do with making sure that the last lb lies on a MB
    // boundary
    Ok(((disk_size - MEGABYTE) / lb_size_bytes) - 1)
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use metalos_disk::test_utils::*;
    use metalos_macros::vmtest;

    fn get_guid(disk_path: &DiskDevPath) -> Result<String> {
        let cfg = gpt::GptConfig::new().writable(false);
        let disk = cfg.open(&disk_path.0).context("failed to open disk")?;

        Ok(disk.guid().to_hyphenated_ref().to_string())
    }

    #[vmtest]
    fn test_expand_last_partition() -> Result<()> {
        let (lo, _) = setup_test_device().context("failed to setup loopback device")?;
        let start_guid = get_guid(&lo).context("failed to get starting guid")?;
        let delta = expand_last_partition(&lo).context("failed to expand last partition")?;
        let ending_guid = get_guid(&lo).context("failed to get starting guid")?;

        println!("{:#?}", delta);
        assert_eq!(delta.partition_num, 2);
        assert_eq!(delta.old_size, 599 * 512);

        // Entire disk should be 51200000 bytes or 100000 sectors we reserve up to
        // 1MB with the formula ((51200000 - (1024 * 1024)) / 512) - 1 = 97951
        assert_eq!(delta.new_last_lb, 97951);

        // start of 3rd part should be sector 201 (102912 bytes).and with the new end
        // at 97951 (50150912) so end size should be 50150912 - 102912 = 50048000
        assert_eq!(delta.new_size, 50048000);

        // Ensure this conversion didn't mess up the guid
        assert_eq!(start_guid, ending_guid);

        Ok(())
    }
}
