# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

# @oss-disable
load("//antlir/antlir2:antlir2_layer_info.bzl", "LayerInfo")
load("//antlir/bzl:build_defs.bzl", "buck_sh_test", "cpp_unittest", "python_unittest", "rust_unittest")

_HIDE_TEST_LABELS = ["disabled", "test_is_invisible_to_testpilot"]

def _impl(ctx: "context") -> ["provider"]:
    test_cmd = cmd_args(
        ctx.attrs.image_test[RunInfo],
        cmd_args(ctx.attrs.layer[LayerInfo].subvol_symlink, format = "--layer={}"),
        cmd_args(ctx.attrs.run_as_user, format = "--user={}"),
        "--boot" if ctx.attrs.boot else cmd_args(),
        cmd_args(ctx.attrs.test[ExternalRunnerTestInfo].env.keys(), format = "--preserve-env={}"),
        ctx.attrs.test[ExternalRunnerTestInfo].test_type,
        ctx.attrs.test[ExternalRunnerTestInfo].command,
    )

    # Copy the labels from the inner test since there is tons of behavior
    # controlled by labels and we don't want to have to duplicate logic that
    # other people are already writing in the standard *_unittest macros.
    # This wrapper should be as invisible as possible.
    inner_labels = list(ctx.attrs.test[ExternalRunnerTestInfo].labels)
    for label in _HIDE_TEST_LABELS:
        inner_labels.remove(label)
    return [
        ExternalRunnerTestInfo(
            command = [test_cmd],
            type = ctx.attrs.test[ExternalRunnerTestInfo].test_type,
            labels = ctx.attrs.labels + inner_labels,
            contacts = ctx.attrs.test[ExternalRunnerTestInfo].contacts,
            env = ctx.attrs.test[ExternalRunnerTestInfo].env,
            run_from_project_root = ctx.attrs.test[ExternalRunnerTestInfo].run_from_project_root,
            use_project_relative_paths = ctx.attrs.test[ExternalRunnerTestInfo].use_project_relative_paths,
        ),
        RunInfo(test_cmd),
        DefaultInfo(),
    ]

image_test = rule(
    impl = _impl,
    attrs = {
        "boot": attrs.bool(default = False, doc = "boot the container with /init as pid1 before running the test"),
        "image_test": attrs.default_only(attrs.exec_dep(default = "//antlir/antlir2/testing/image_test:image-test")),
        "labels": attrs.list(attrs.string(), default = []),
        "layer": attrs.dep(providers = [LayerInfo]),
        "run_as_user": attrs.string(default = "root"),
        "test": attrs.dep(providers = [ExternalRunnerTestInfo]),
    },
    doc = "Run a test inside an image layer",
)

# Collection of helpers to create the inner test implicitly, and hide it from
# TestPilot

def _implicit_image_test(
        test_rule,
        name: str.type,
        layer: str.type,
        run_as_user: [str.type, None] = None,
        labels: [[str.type], None] = None,
        boot: bool.type = False,
        **kwargs):
    test_rule(
        name = name + "_image_test_inner",
        antlir_rule = "user-internal",
        labels = _HIDE_TEST_LABELS,
        **kwargs
    )
    labels = list(labels) if labels else []
    image_test(
        name = name,
        layer = layer,
        run_as_user = run_as_user,
        test = ":" + name + "_image_test_inner",
        labels = labels + [special_tags.enable_artifact_reporting],
        boot = boot,
    )

image_cpp_test = partial(_implicit_image_test, cpp_unittest)
image_python_test = partial(_implicit_image_test, python_unittest)
image_rust_test = partial(_implicit_image_test, rust_unittest)
image_sh_test = partial(_implicit_image_test, buck_sh_test)