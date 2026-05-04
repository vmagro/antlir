# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

def build_appliance_from_dir(name, dir, visibility = None):
    native.alias(
        name = name,
        actual = dir,
        visibility = visibility,
    )
