# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

load("//antlir/antlir2/bzl:platform.bzl", "rule_with_default_target_platform")
load("//antlir/antlir2/bzl:types.bzl", "LayerInfo")

SendstreamInfo = provider(fields = [
    "sendstream",  # 'artifact' that is the btrfs sendstream
    "subvol_symlink",  # subvol that was actually packaged
    "layer",  # layer that was packaged
])

_base_sendstream_args_defaults = {
    "volume_name": "volume",
}

_base_sendstream_args = {
    "antlir2_packager": attrs.default_only(attrs.exec_dep(default = "//antlir/antlir2/antlir2_packager:antlir2-packager")),
    "build_appliance": attrs.option(attrs.dep(providers = [LayerInfo]), default = None),
    "incremental_parent": attrs.option(
        attrs.dep(
            providers = [SendstreamInfo],
            doc = "create an incremental sendstream using this parent layer",
        ),
        default = None,
    ),
    "layer": attrs.dep(providers = [LayerInfo]),
    "volume_name": attrs.string(default = _base_sendstream_args_defaults["volume_name"]),
}

def _is_ancestor(*, layer: LayerInfo, parent: Dependency):
    if not layer.parent:
        return False
    elif layer.parent.label == parent.label:
        return True
    else:
        return _is_ancestor(layer = layer.parent[LayerInfo], parent = parent)

def _impl(ctx: AnalysisContext) -> list[Provider]:
    sendstream = ctx.actions.declare_output("image.sendstream")
    subvol_symlink = ctx.actions.declare_output("subvol_symlink")

    incremental_parent = ctx.attrs.incremental_parent
    if incremental_parent:
        if not _is_ancestor(layer = ctx.attrs.layer[LayerInfo], parent = incremental_parent[SendstreamInfo].layer):
            fail("{} is not an ancestor of {}".format(
                incremental_parent.label.raw_target(),
                ctx.attrs.layer.label.raw_target(),
            ))

    spec = ctx.actions.write_json(
        "spec.json",
        {"sendstream": {
            "build_appliance": (ctx.attrs.build_appliance or ctx.attrs.layer[LayerInfo].build_appliance)[LayerInfo].subvol_symlink,
            "incremental_parent": incremental_parent[SendstreamInfo].subvol_symlink if incremental_parent else None,
            "layer": ctx.attrs.layer[LayerInfo].subvol_symlink,
            "subvol_symlink": subvol_symlink.as_output(),
            "volume_name": ctx.attrs.volume_name,
        }},
        with_inputs = True,
    )
    ctx.actions.run(
        cmd_args(
            "sudo",
            ctx.attrs.antlir2_packager[RunInfo],
            cmd_args(spec, format = "--spec={}"),
            cmd_args(sendstream.as_output(), format = "--out={}"),
        ),
        local_only = True,  # needs root and local subvol
        category = "antlir2_package",
        env = {"RUST_LOG": "trace"},
    )
    return [
        DefaultInfo(sendstream),
        SendstreamInfo(
            sendstream = sendstream,
            subvol_symlink = subvol_symlink,
            layer = ctx.attrs.layer,
        ),
    ]

_sendstream = anon_rule(
    impl = _impl,
    attrs = _base_sendstream_args,
    artifact_promise_mappings = {
        "anon_v1_sendstream": lambda x: x[SendstreamInfo].sendstream,
    },
)

sendstream = rule_with_default_target_platform(_sendstream)

def anon_v1_sendstream(
        *,
        ctx: AnalysisContext,
        layer: Dependency | None = None,
        build_appliance: Dependency | None = None) -> AnonTarget:
    attrs = {
        key: getattr(ctx.attrs, key, _base_sendstream_args_defaults.get(key, None))
        for key in _base_sendstream_args
    }
    if layer:
        attrs["layer"] = layer
    if build_appliance:
        attrs["build_appliance"] = build_appliance
    return ctx.actions.anon_target(
        _sendstream,
        attrs,
    )

def _zst_impl(ctx: AnalysisContext) -> Promise:
    sendstream_zst = ctx.actions.declare_output("image.sendstream.zst")

    def _map(providers: ProviderCollection) -> list[Provider]:
        v1_sendstream = providers[SendstreamInfo].sendstream
        ctx.actions.run(
            cmd_args(
                "zstd",
                "--compress",
                cmd_args(str(ctx.attrs.compression_level), format = "-{}"),
                "-o",
                sendstream_zst.as_output(),
                v1_sendstream,
            ),
            category = "compress",
            local_only = True,  # zstd not available on RE
        )
        return [
            DefaultInfo(sendstream_zst),
            SendstreamInfo(
                sendstream = sendstream_zst,
                subvol_symlink = providers[SendstreamInfo].subvol_symlink,
                layer = providers[SendstreamInfo].layer,
            ),
        ]

    return anon_v1_sendstream(ctx = ctx).promise.map(_map)

_sendstream_zst = rule(
    impl = _zst_impl,
    attrs = {
        "compression_level": attrs.int(default = 3),
    } | _base_sendstream_args,
)

sendstream_zst = rule_with_default_target_platform(_sendstream_zst)

def _v2_impl(ctx: AnalysisContext) -> Promise:
    sendstream_v2 = ctx.actions.declare_output("image.sendstream.v2")

    def _map(providers: ProviderCollection) -> list[Provider]:
        v1_sendstream = providers[SendstreamInfo].sendstream

        ctx.actions.run(
            cmd_args(
                ctx.attrs.sendstream_upgrader[RunInfo],
                cmd_args(str(ctx.attrs.compression_level), format = "--compression-level={}"),
                cmd_args(v1_sendstream, format = "--input={}"),
                cmd_args(sendstream_v2.as_output(), format = "--output={}"),
            ),
            category = "sendstream_upgrade",
            # This _can_ run remotely, but we've just produced the (often quite
            # large) sendstream artifact on this host, and we only care about the
            # final result of this v2 sendstream, so we should prefer to run locally
            # to avoid uploading and downloading many gigabytes of artifacts
            prefer_local = True,
        )
        return [
            DefaultInfo(sendstream_v2),
            SendstreamInfo(
                sendstream = sendstream_zst,
                subvol_symlink = providers[SendstreamInfo].subvol_symlink,
                layer = providers[SendstreamInfo].layer,
            ),
        ]

    return anon_v1_sendstream(ctx = ctx).promise.map(_map)

_sendstream_v2 = rule(
    impl = _v2_impl,
    attrs = {
        "compression_level": attrs.int(default = 3),
        "sendstream_upgrader": attrs.default_only(attrs.exec_dep(default = "//antlir/btrfs_send_stream_upgrade:btrfs_send_stream_upgrade")),
    } | _base_sendstream_args,
)

sendstream_v2 = rule_with_default_target_platform(_sendstream_v2)
