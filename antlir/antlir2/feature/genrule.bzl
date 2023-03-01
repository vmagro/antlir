# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

load(":feature_info.bzl", "InlineFeatureInfo")

def genrule(
        *,
        cmd: [str.type],
        user: str.type,
        bind_repo_ro: bool.type = False,
        boot: bool.type = False) -> InlineFeatureInfo.type:
    return InlineFeatureInfo(
        feature_type = "genrule",
        kwargs = {
            "bind_repo_ro": bind_repo_ro,
            "boot": boot,
            "cmd": cmd,
            "user": user,
        },
    )

def genrule_to_json(
        cmd: [str.type],
        user: str.type,
        bind_repo_ro: bool.type = False,
        boot: bool.type = False) -> {str.type: ""}:
    return {
        "bind_repo_ro": bind_repo_ro,
        "boot": boot,
        "cmd": cmd,
        "user": user,
    }
