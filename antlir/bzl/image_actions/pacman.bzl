load("@bazel_skylib//lib:types.bzl", "types")
load("//antlir/bzl:target_tagger.bzl", "image_source_as_target_tagged_dict", "new_target_tagger", "target_tagger_to_feature")

def _pkg_name_or_source(name_source):
    # Normal pkg names cannot have a colon, whereas target paths
    # ALWAYS have a colon. `image.source` is a struct.
    if not types.is_string(name_source) or ":" in name_source:
        return "source"
    else:
        return "name"

# It'd be a bit expensive to do any kind of validation of RPM
# names at this point, since we'd need the repo snapshot to decide
# whether the names are valid, and whether they contain a
# version or release number.  That'll happen later in the build.
def _build_pacman_feature(rpmlist, action):
    target_tagger = new_target_tagger()
    res_pkgs = []
    for path in rpmlist:
        dct = {"action": action, _pkg_name_or_source(path): path}

        if dct.get("source") != None:
            dct["source"] = image_source_as_target_tagged_dict(
                target_tagger,
                dct["source"],
            )
        else:
            dct["source"] = None  # Ensure this key is populated
        res_pkgs.append(dct)
    return target_tagger_to_feature(
        target_tagger = target_tagger,
        items = struct(pacman_packages = res_pkgs),
        # The `fake_macro_library` docblock explains this self-dependency
        # extra_deps = ["//antlir/bzl/image_actions:pacman-item"],
    )

def image_pacman_install(pkglist):
    return _build_pacman_feature(pkglist, "install")

def image_pacman_remove_if_exists(pkglist):
    return _build_pacman_feature(
        pkglist,
        "remove_if_exists",
    )
