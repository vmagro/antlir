# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

"""
Compatibility shims for antlir1->antlir2 migration
This file must load on both buck1 and buck2
"""

load("//antlir/bzl:build_defs.bzl", "is_buck2")
load("//antlir/bzl:constants.bzl", "BZL_CONST")
load("//antlir/bzl:image.bzl", "image")
load("//antlir/bzl:image_layer_utils.bzl", "image_layer_utils")
load("//antlir/bzl:target_helpers.bzl", "normalize_target")
load("//antlir/bzl/image/feature:defs.bzl", "feature")

# THAR BE DRAGONS
# DO NOT ADD ANYTHING HERE WITHOUT THE APPROVAL OF @vmagro OR @lsalis
# THIS IS FULL OF FOOTGUNS AND YOU SHOULDN'T USE IT WITHOUT KNOWING EXACTLY WHAT
# YOU'RE DOING
_ALLOWED_LABELS = ("fbcode//antlir/antlir2/antlir1_compat/tests:antlir1-layer",)

def _make_cmd(location, force_flavor):
    return """
        set -ex
        location={location}
        mkdir "$subvolume_wrapper_dir"
        dst_rel="$subvolume_wrapper_dir/volume"
        dst_abs="$SUBVOLUMES_DIR/$dst_rel"
        sudo btrfs subvolume snapshot "$location" "$dst_abs"
        sudo mkdir "$dst_abs/.meta"
        echo -n "{force_flavor}" | sudo tee "$dst_abs/.meta/flavor"
        uuid=`sudo btrfs subvolume show "$dst_abs" | grep UUID: | grep -v "Parent UUID:" | grep -v "Received UUID:" | cut -f5`
        jq --null-input \\
            --arg subvolume_rel_path "$dst_rel" \\
            --arg uuid "$uuid" \\
            --arg hostname "$HOSTNAME" \\
            '{{"subvolume_rel_path": $subvolume_rel_path, "btrfs_uuid": $uuid, "hostname": $hostname, "build_appliance_path": "/"}}' \\
            > "$layer_json"
    """.format(
        location = location,
        force_flavor = force_flavor,
    )

def _common(name, location, rule_type, force_flavor, antlir_rule = "user-facing", **kwargs):
    if normalize_target(":" + name) not in _ALLOWED_LABELS:
        fail("'{}' has not been approved for use with antlir2's compat mode".format(normalize_target(":" + name)))
    features_for_layer = name + "--antlir2-inner" + BZL_CONST.layer_feature_suffix
    feature.new(
        name = features_for_layer,
        features = [],
    )
    image_layer_utils.image_layer_impl(
        _layer_name = name + "--antlir2-inner",
        _rule_type = rule_type,
        _make_subvol_cmd = _make_cmd(
            location = location,
            force_flavor = force_flavor,
        ),
        # sorry buck1 users, builds might be stale, deal with it or move to
        # buck2 and enjoy faster, more correct builds ;p
        _deps_query = None,
        antlir_rule = "user-internal",
        visibility = [normalize_target(":" + name)],
    )
    image.layer(
        name = name,
        antlir_rule = antlir_rule,
        parent_layer = ":" + name + "--antlir2-inner",
        flavor = force_flavor,
        **kwargs
    )

def _export_for_antlir1_buck1(name, layer, **kwargs):
    _common(
        name,
        location = """`buck2 build --show-full-json-output "{full_label}" | jq -r '.["{full_label}"]'`""".format(
            full_label = normalize_target(layer),
        ),
        rule_type = "antlir2_buck1_compat",
        **kwargs
    )

def _export_for_antlir1_buck2(name, layer, **kwargs):
    _common(
        name,
        location = "$(location {})".format(layer),
        rule_type = "antlir2_compat",
        **kwargs
    )

export_for_antlir1 = _export_for_antlir1_buck2 if is_buck2() else _export_for_antlir1_buck1