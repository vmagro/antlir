# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

load("//antlir/antlir2/bzl/feature:defs.bzl?v2_only", antlir2 = "feature")
load("//antlir/bzl:shape.bzl", "shape")

def feature_ensure_dirs_exist(
        path,
        mode = shape.DEFAULT_VALUE,
        user = shape.DEFAULT_VALUE,
        group = shape.DEFAULT_VALUE):
    """Equivalent to `feature.ensure_subdirs_exist("/", path, ...)`."""
    return feature_ensure_subdirs_exist(
        into_dir = "/",
        subdirs_to_create = path,
        mode = mode,
        user = user,
        group = group,
    )

def feature_ensure_subdirs_exist(
        into_dir,
        subdirs_to_create,
        mode = shape.DEFAULT_VALUE,
        user = shape.DEFAULT_VALUE,
        group = shape.DEFAULT_VALUE):
    """
  `feature.ensure_subdirs_exist("/w/x", "y/z")` creates the directories `/w/x/y`
  and `/w/x/y/z` in the image, if they do not exist. `/w/x` must have already
  been created by another image feature. If any dirs to be created already exist
  in the image, their attributes will be checked to ensure they match the
  attributes provided here. If any do not match, the build will fail.

  The arguments `into_dir` and `subdirs_to_create` are mandatory; `mode`,
  `user`, and `group` are optional.

  The argument `mode` changes file mode bits of all directories in
  `subdirs_to_create`. It can be an integer fully specifying the bits or a
  symbolic string like `u+rx`. In the latter case, the changes are applied on
  top of mode 0.

  The arguments `user` and `group` change file owner and group of all
  directories in `subdirs_to_create`. `user` and `group` can be integers or
  symbolic strings. In the latter case, the passwd/group database from the host
  (not from the image) is used.
    """
    return antlir2.ensure_subdirs_exist(
        into_dir = into_dir,
        subdirs_to_create = subdirs_to_create,
        mode = mode if mode != shape.DEFAULT_VALUE else 0o755,
        user = user if user != shape.DEFAULT_VALUE else "root",
        group = group if group != shape.DEFAULT_VALUE else "root",
    )
