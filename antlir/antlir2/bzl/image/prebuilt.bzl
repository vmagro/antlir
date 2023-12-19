# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

load("//antlir/antlir2/bzl:platform.bzl", "rule_with_default_target_platform")
load("//antlir/antlir2/bzl:types.bzl", "FlavorInfo", "LayerInfo")
load(":depgraph.bzl", "build_depgraph")

PrebuiltImageInfo = provider(fields = [
    "format",  # format of the image file
    "source",  # source file of the image
])

def _impl(ctx: AnalysisContext) -> list[Provider]:
    format = ctx.attrs.format
    src = ctx.attrs.src
    if format == "sendstream.zst":
        format = "sendstream"
    if format == "sendstream":
        if ctx.attrs.src.basename.endswith("zst"):
            src = ctx.actions.declare_output("uncompressed")
            ctx.actions.run(
                cmd_args(
                    "zstd",
                    "-d",
                    "-o",
                    src.as_output(),
                    ctx.attrs.src,
                ),
                category = "decompress",
                # we absolutely need the end result locally to `btrfs receive`
                # it, and these images are often huge and spend a ton of time
                # uploading and downloading giant blobs to/from RE
                local_only = True,
            )
    elif format == "sendstream.v2":
        # antlir2-receive treats them the same
        format = "sendstream"

    if format == "tar":
        if ctx.attrs.src.basename.endswith("gz"):
            src = ctx.actions.declare_output("uncompressed")
            ctx.actions.run(
                cmd_args(
                    "bash",
                    "-e",
                    "-c",
                    cmd_args(
                        "zcat",
                        ctx.attrs.src,
                        cmd_args(src.as_output(), format = "> {}"),
                        delimiter = " ",
                    ),
                ),
                category = "decompress",
                # we're going to need it to be locally available to extract it
                # into an image, but it *can* be run remotely
                prefer_local = True,
            )

    _make_recv_action = lambda rootless, out: ctx.actions.run(
        cmd_args(
            # this usually requires privileged btrfs operations
            "sudo" if not rootless else cmd_args(),
            ctx.attrs.antlir2_receive[RunInfo],
            "--working-dir=antlir2-out",
            cmd_args(str(ctx.label), format = "--label={}"),
            cmd_args(format, format = "--format={}"),
            cmd_args(src, format = "--source={}"),
            cmd_args(out.as_output(), format = "--output={}"),
            cmd_args("--rootless") if rootless else cmd_args(),
        ),
        category = "antlir2_prebuilt_layer" + ("_rootless" if rootless else ""),
        # needs local subvolumes
        local_only = True,
        # the old output is used to clean up the local subvolume
        no_outputs_cleanup = True,
        env = {
            "RUST_LOG": "antlir2=trace",
        },
    )

    subvol_symlink = ctx.actions.declare_output("subvol_symlink")
    subvol_symlink_rootless = ctx.actions.declare_output("subvol_symlink_rootless")

    _make_recv_action(False, subvol_symlink)
    _make_recv_action(True, subvol_symlink_rootless)

    _make_depgraph = lambda rootless, subvol: build_depgraph(
        ctx = ctx,
        parent_depgraph = None,
        features_json = None,
        format = "json",
        subvol = subvol,
        dependency_layers = [],
        rootless = rootless,
    )

    depgraph_output = _make_depgraph(False, subvol_symlink)
    depgraph_output_rootless = _make_depgraph(True, subvol_symlink_rootless)

    if not ctx.attrs.antlir_internal_build_appliance and not ctx.attrs.flavor:
        fail("only build appliance images are allowed to be flavorless")
    return [
        LayerInfo(
            label = ctx.label,
            depgraph = depgraph_output,
            subvol_symlink = subvol_symlink,
            mounts = [],
            flavor = ctx.attrs.flavor,
            rootless = False,
        ),
        DefaultInfo(subvol_symlink, sub_targets = {
            "rootless": [
                DefaultInfo(subvol_symlink_rootless),
                LayerInfo(
                    label = ctx.label,
                    depgraph = depgraph_output_rootless,
                    subvol_symlink = subvol_symlink_rootless,
                    mounts = [],
                    flavor = ctx.attrs.flavor,
                    rootless = True,
                ),
            ],
        }),
    ]

_prebuilt = rule(
    impl = _impl,
    attrs = {
        "antlir2": attrs.exec_dep(default = "//antlir/antlir2/antlir2:antlir2"),
        "antlir2_receive": attrs.default_only(attrs.exec_dep(default = "//antlir/antlir2/antlir2_receive:antlir2-receive")),
        "antlir_internal_build_appliance": attrs.bool(default = False, doc = "mark if this image is a build appliance and is allowed to not have a flavor"),
        "flavor": attrs.option(attrs.dep(providers = [FlavorInfo]), default = None),
        "format": attrs.enum(["cas_dir", "sendstream.v2", "sendstream", "sendstream.zst", "tar"]),
        "labels": attrs.list(attrs.string(), default = []),
        "src": attrs.source(doc = "source file of the image"),
    },
)

prebuilt = rule_with_default_target_platform(_prebuilt)
