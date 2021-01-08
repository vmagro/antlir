load("//antlir/bzl/image_actions:install.bzl", "image_install")
load("//antlir/bzl/image_actions:remove.bzl", "image_remove")
load("//antlir/bzl/image_actions:ensure_dirs_exist.bzl", "image_ensure_dirs_exist")
load("//antlir/bzl/image_actions:symlink.bzl", "image_symlink_dir")
load(":snapshot_install_dir.bzl", "RPM_DEFAULT_SNAPSHOT_FOR_INSTALLER_DIR", "snapshot_install_dir")

def install_archlinux_archive_snapshot(snapshot):
    """
    Returns an `image.feature`, which installs the `rpm_repo_snapshot`
    target in `snapshot` in its canonical location.

    The layer must also include `set_up_rpm_repo_snapshots()`.

    A layer that installs snapshots should be followed by a
    `image_yum_dnf_make_snapshot_cache` layer so that `yum` / `dnf` repodata
    caches are properly populated.  Otherwise, RPM installs will be slow.
    """
    return [
        image_ensure_dirs_exist(snapshot_install_dir(snapshot)),
        image_install(snapshot, snapshot_install_dir(snapshot) + "/pacman.conf"),
    ]

def default_archlinux_archive_snapshot(snapshot):
    """
    Set the default snapshot for the given RPM installer.  The snapshot must
    have been installed by `install_rpm_repo_snapshot()`.
    """

    link_name = RPM_DEFAULT_SNAPSHOT_FOR_INSTALLER_DIR + "/pacman"
    return [
        # Silently replace the parent's default because there's not an
        # obvious scenario in which this is an error, and so forcing the
        # user to pass an explicit `replace_existing` flag seems unhelpful.
        image_remove(link_name, must_exist = False),
        image_symlink_dir(snapshot_install_dir(snapshot), link_name),
    ]
