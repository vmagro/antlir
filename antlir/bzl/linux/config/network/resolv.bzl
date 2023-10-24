# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

load("//antlir/antlir2/bzl/feature:defs.bzl?v2_only", antlir2_feature = "feature")
load("//antlir/bzl:sha256.bzl", "sha256_b64")
load("//antlir/bzl:shape.bzl", "shape")
load("//antlir/bzl/image/feature:defs.bzl", antlir1_feature = "feature")
load(":resolv.shape.bzl", "conf_t")

def _new(**kwargs):
    return conf_t(**kwargs)

def _render(name, instance):
    return shape.render_template(
        name = name,
        instance = instance,
        template = "//antlir/bzl/linux/config/network:resolv",
    )

def _install(instance = None, use_antlir2 = False, **kwargs):
    contents_hash = sha256_b64(str(kwargs))
    name = "resolv.conf--" + contents_hash

    if not instance:
        instance = conf_t(**kwargs)

    file = _render(
        name = name,
        instance = instance,
    )
    if use_antlir2:
        return antlir2_feature.install(
            src = file,
            dst = "/etc/resolv.conf",
        )
    return antlir1_feature.install(
        file,
        "/etc/resolv.conf",
    )

# exported api to instantiate a resolv.conf config
resolv = struct(
    t = conf_t,
    new = _new,
    install = _install,
    default = conf_t(
        search_domains = [],
        nameservers = ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"],
    ),
)
