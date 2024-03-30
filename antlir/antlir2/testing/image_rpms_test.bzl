# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

load("//antlir/antlir2/bzl/feature:defs.bzl", "feature")
load("//antlir/antlir2/bzl/image:cfg.bzl", "cfg_attrs", "layer_cfg")
load("//antlir/antlir2/bzl/image:defs.bzl", "image")
load("//antlir/antlir2/os:package.bzl", "get_default_os_for_package")
load("//antlir/antlir2/testing:image_test.bzl", "image_sh_test")

def _rpm_names_test_impl(ctx: AnalysisContext) -> list[Provider]:
    return [
        DefaultInfo(),
        RunInfo(cmd_args(
            ctx.attrs.image_rpms_test[RunInfo],
            "names",
            ctx.attrs.src,
            "--",
            "--layer=/layer",
            cmd_args("--not-installed") if ctx.attrs.not_installed else cmd_args(),
        )),
    ]

_rpm_names_test = rule(
    impl = _rpm_names_test_impl,
    attrs = {
        "antlir_internal_build_appliance": attrs.default_only(attrs.bool(default = False), doc = "read by cfg.bzl"),
        "image_rpms_test": attrs.default_only(attrs.exec_dep(default = "//antlir/antlir2/testing/image_rpms_test:image-rpms-test")),
        "not_installed": attrs.bool(default = False),
        "src": attrs.source(),
    } | cfg_attrs(),
    cfg = layer_cfg,
)

def image_test_rpm_names(
        name: str,
        src: str | Select,
        layer: str,
        not_installed: bool = False,
        default_os: str | None = None,
        **kwargs):
    image.layer(
        name = name + "--layer",
        force_flavor = layer + "[flavor]",
        features = [
            feature.rpms_install(rpms = ["rpm"]),
            feature.layer_mount(
                source = layer,
                mountpoint = "/layer",
            ),
        ],
    )

    _rpm_names_test(
        name = name + "--script",
        src = src,
        not_installed = not_installed,
        default_os = default_os or get_default_os_for_package(),
    )

    image_sh_test(
        name = name,
        test = ":{}--script".format(name),
        layer = ":{}--layer".format(name),
        default_os = default_os or get_default_os_for_package(),
        **kwargs
    )

def _rpm_integrity_test_impl(ctx: AnalysisContext) -> list[Provider]:
    return [
        DefaultInfo(),
        RunInfo(cmd_args(
            ctx.attrs.image_rpms_test[RunInfo],
            "integrity",
            # image_test generally does not add this because it needs to parse
            # options intended for the end test in the case of things like
            # python_unittest. Add -- explicitly so that `image-test` does not
            # try to parse our rpm test options
            "--",
            cmd_args(ctx.attrs.ignored_files, format = "--ignored-file={}"),
            cmd_args(ctx.attrs.ignored_rpms, format = "--ignored-rpm={}"),
            "--layer=/layer",
        )),
    ]

_rpm_integrity_test = rule(
    impl = _rpm_integrity_test_impl,
    attrs = {
        "ignored_files": attrs.list(attrs.string(doc = "path that is allowed to fail integrity test"), default = []),
        "ignored_rpms": attrs.list(attrs.string(doc = "name of rpm that is ignored for integrity checks"), default = []),
        "image_rpms_test": attrs.default_only(attrs.exec_dep(default = "//antlir/antlir2/testing/image_rpms_test:image-rpms-test")),
    },
)

def image_test_rpm_integrity(
        name: str,
        layer: str,
        ignored_files: list[str] | Select = [],
        ignored_rpms: list[str] | Select = [],
        default_os: str | None = None,
        **kwargs):
    """
    Verify the integrity of all installed RPMs to ensure that any changes done
    by an image will not be undone by any runtime rpm installation.
    """
    _rpm_integrity_test(
        name = name + "--script",
        ignored_files = ignored_files,
        ignored_rpms = ignored_rpms,
    )
    image.layer(
        name = name + "--layer",
        force_flavor = layer + "[flavor]",
        features = [
            feature.rpms_install(rpms = ["rpm"]),
            feature.layer_mount(
                source = layer,
                mountpoint = "/layer",
            ),
        ],
    )
    image_sh_test(
        name = name,
        layer = ":{}--layer".format(name),
        test = ":{}--script".format(name),
        default_os = default_os or get_default_os_for_package(),
        **kwargs
    )
