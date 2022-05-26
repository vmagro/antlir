use std::marker::PhantomData;
use std::path::PathBuf;

use crate::layer::AntlirLayer;
use crate::path::VerifiedPath;

pub struct AntlirSubvolume<L: AntlirLayer> {
    pub relative_path: PathBuf,
    layer: PhantomData<L>,
}

impl<L: AntlirLayer> AntlirSubvolume<L> {
    pub fn new_unchecked(relative_path: PathBuf) -> Self {
        Self {
            relative_path,
            layer: Default::default(),
        }
    }

    pub fn mount_unchecked(&self, target: VerifiedPath) -> L {
        L::new_unchecked(target)
    }
}

/// A marker trait indicating that this struct is actually
/// generated by the macro below.
pub trait AntlirSubvolumes: crate::AntlirPackaged {
    fn new_unchecked() -> Self;
}

#[macro_export]
macro_rules! generate_subvolumes {
    ($name:ident { $($subvol_name:ident ($subvol_type:ty, $path:tt)),* $(,)* }) => {
        pub struct $name {}

        impl $crate::AntlirPackaged for $name {}
        impl $crate::subvolume::AntlirSubvolumes for $name {
            fn new_unchecked() -> Self {
                Self { }
            }
        }

        impl $name {
            $(
                #[allow(dead_code)]
                pub fn $subvol_name(&self) -> $subvol_type {
                    $crate::subvolume::AntlirSubvolume::new_unchecked($path.into())
                }
            )*
        }
    }
}
