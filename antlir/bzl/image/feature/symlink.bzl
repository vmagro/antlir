# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

load("//antlir/antlir2/bzl/feature:defs.bzl?v2_only", antlir2 = "feature")

def feature_ensure_dir_symlink(link_target, link_name):
    """
The operation follows rsync convention for a destination (`link_name`):
`ends/in/slash/` means "write into this directory", `does/not/end/with/slash`
means "write with the specified filename":

- `feature.ensure_dir_symlink("/d", "/e/")` symlinks directory `/d` to `/e/d`
- `feature.ensure_dir_symlink("/a", "/b/c")` symlinks directory `/a` to `/b/c`

Both arguments are mandatory:

- `link_target` is the image-absolute source file/dir of the symlink.
    This file must exist as we do not support dangling symlinks.

    IMPORTANT: The emitted symlink will be **relative** by default, enabling
    easier inspection if images via `buck-image-out`. If this is a problem
    for you, we can add an `absolute` boolean kwarg.

- `link_name` is an image-absolute path. A trailing / is significant.

    A `link_name` that does NOT end in / is a full path in the new image,
    ending with a filename for the new symlink.

    As with `image.clone`, a traling / means that `link_name` must be a
    pre-existing directory in the image (e.g. created via
    `feature.ensure_dirs_exist`), and the actual link will be placed at
    `link_name/(basename of link_target)`.

This item is indempotent: it is a no-op if a symlink already exists that
matches the spec.
    """
    return antlir2.ensure_dir_symlink(
        link = link_name,
        target = link_target,
    )

def feature_ensure_file_symlink(link_target, link_name):
    """
The operation follows rsync convention for a destination (`link_name`):
`ends/in/slash/` means "write into this directory", `does/not/end/with/slash`
means "write with the specified filename":

- `feature.ensure_file_symlink("/d", "/e/")` symlinks file `/d` to `/e/d`
- `feature.ensure_file_symlink("/a", "/b/c")` symlinks file `/a` to `/b/c`

Both arguments are mandatory:

- `link_target` is the image-absolute source file/dir of the symlink.
    This file must exist as we do not support dangling symlinks.

    IMPORTANT: The emitted symlink will be **relative** by default, enabling
    easier inspection if images via `buck-image-out`. If this is a problem
    for you, we can add an `absolute` boolean kwarg.

- `link_name` is an image-absolute path. A trailing / is significant.

    A `link_name` that does NOT end in / is a full path in the new image,
    ending with a filename for the new symlink.

    As with `image.clone`, a traling / means that `link_name` must be a
    pre-existing directory in the image (e.g. created via
    `feature.ensure_dirs_exist`), and the actual link will be placed at
    `link_name/(basename of link_target)`.

This item is indempotent: it is a no-op if a symlink already exists that
matches the spec.
    """
    return antlir2.ensure_file_symlink(
        link = link_name,
        target = link_target,
    )
