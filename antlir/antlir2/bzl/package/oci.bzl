# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

load("//antlir/buck2/bzl:ensure_single_output.bzl", "ensure_single_output")
load(":cfg.bzl", "layer_attrs", "package_cfg")
load(":defs.bzl", "common_attrs", "default_attrs", "tar_anon", "tar_zst_rule")
load(":macro.bzl", "package_macro")

def _impl(ctx: AnalysisContext) -> Promise:
    def with_anon(tars) -> list[Provider]:
        out = ctx.actions.declare_output(ctx.label.name, dir = True)

        # Need both a compressed tar (to actually put in the archive) and
        # uncompressed (to record the uncompressed checksum)
        tar = ensure_single_output(tars[0])
        tar_zst = ensure_single_output(tars[1])
        spec = ctx.actions.write_json(
            "spec.json",
            {"oci": {
                "entrypoint": ctx.attrs.entrypoint,
                "ref": ctx.attrs.ref,
                "tar": tar,
                "tar_zst": tar_zst,
                "target_arch": ctx.attrs._target_arch,
            }},
            with_inputs = True,
        )
        ctx.actions.run(
            cmd_args(
                ctx.attrs._antlir2_packager[RunInfo],
                "--dir",
                cmd_args(out.as_output(), format = "--out={}"),
                cmd_args(spec, format = "--spec={}"),
            ),
            category = "antlir2_package",
            identifier = "oci",
        )
        return [
            DefaultInfo(out, sub_targets = {"tar": [DefaultInfo(tar)]}),
            RunInfo(cmd_args(out)),
        ]

    all_attrs = {
        k: getattr(ctx.attrs, k)
        for k in list(layer_attrs) + list(common_attrs) + list(default_attrs) + ["_rootless"]
    }

    return ctx.actions.anon_targets([
        (
            tar_anon,
            {"name": str(ctx.attrs.layer.label.raw_target())} | all_attrs,
        ),
        (
            tar_zst_rule,
            {"name": str(ctx.attrs.layer.label.raw_target())} | all_attrs,
        ),
    ]).promise.map(with_anon)

oci_attrs = {
    "entrypoint": attrs.list(attrs.string(), doc = "Command to run as the main process"),
    "ref": attrs.string(
        default = native.read_config("build_info", "revision", "local"),
        doc = "Ref name for OCI image",
    ),
}

oci_rule = rule(
    impl = _impl,
    attrs = oci_attrs | layer_attrs | default_attrs | common_attrs,
    cfg = package_cfg,
)

oci = package_macro(oci_rule)
