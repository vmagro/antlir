# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

load("//antlir/bzl:build_defs.bzl", "is_buck2")
load("//antlir/bzl:constants.bzl", "REPO_CFG")

# if shape.bzl wants to start using this library, we can change the check for shape.DEFAULT_VALUE
load("//antlir/bzl:shape.bzl", "shape")

def _is_early_adopter():
    if not is_buck2():
        return False
    current_package = native.package_name()
    if current_package in REPO_CFG.buck2_early_adoption.exclude:
        return False
    for package in REPO_CFG.buck2_early_adoption.exclude:
        if current_package.startswith(package + "/"):
            return False
    if current_package in REPO_CFG.buck2_early_adoption.include:
        return True
    for package in REPO_CFG.buck2_early_adoption.include:
        if current_package.startswith(package + "/"):
            return True
    return False

# these kwargs existed because of limitations in buck1, and we don't need to
# carry them forward
_drop_legacy_kwargs = (
    "antlir_rule",
)

# remove kwargs that are None, and remove shape.DEFAULT_VALUE
def _massage_kwargs(**kwargs) -> {str.type: ""}:
    return {
        k: v
        for k, v in kwargs.items()
        if v != None and v != shape.DEFAULT_VALUE and k not in _drop_legacy_kwargs
    }

buck2_early_adoption = struct(
    is_early_adopter = _is_early_adopter,
    massage_kwargs = _massage_kwargs,
)