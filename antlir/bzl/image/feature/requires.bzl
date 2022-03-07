# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

load("//antlir/bzl:shape.bzl", "shape")
load("//antlir/bzl:target_tagger.bzl", "new_target_tagger", "target_tagger_to_feature")
load(":requires.shape.bzl", "requires_t")

def feature_requires(
        users = None,
        groups = None):
    """
`feature.requires(...)` adds macro-level requirements on image layers.

Currently this supports requiring users and groups to exist in the layer being
built. This feature doesn't materialize anything in the built image, but it will
cause a compiler error if any of the users/groups that are requested do not
exist in either the `parent_layer` or the layer being built.

An example of a reasonable use-case of this functionality is defining a macro
that generates systemd units that run as a specific user, where
`feature.requires` can be used for additional compile-time safety that the user
does indeed exist.
"""
    req = shape.new(
        requires_t,
        users = users,
        groups = groups,
    )
    return target_tagger_to_feature(
        new_target_tagger(),
        items = struct(requires = [req]),
        # The `fake_macro_library` docblock explains this self-dependency
        extra_deps = ["//antlir/bzl/image/feature:requires"],
    )
