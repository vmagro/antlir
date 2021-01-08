#!/usr/bin/env python3
# Copyright (c) Facebook, Inc. and its affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

import enum
import os
import pwd
import shlex
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Iterable, List, Mapping, NamedTuple, Optional, Tuple, Union

from antlir.fs_utils import (
    RPM_DEFAULT_SNAPSHOT_FOR_INSTALLER_DIR,
    Path,
    generate_work_dir,
)
from antlir.nspawn_in_subvol.args import (
    NspawnPluginArgs,
    PopenArgs,
    new_nspawn_opts,
)
from antlir.nspawn_in_subvol.nspawn import run_nspawn
from antlir.subvol_utils import Subvol

from .common import ImageItem, LayerOpts, PhaseOrder, protected_path_set


class PacmanAction(enum.Enum):
    install = "install"
    remove_if_exists = "remove_if_exists"


# The values are valid `pacman` commands.
class PacmanCommand(enum.Enum):
    # pacman -S installs the named package and its dependencies from a remote
    # repository
    install_name = "--sync"
    # pacman -U accepts local paths
    local_install = "--upgrade"
    # TODO(vmagro): what happens if this doesn't exist?
    remove_name_if_exists = "--remove"


# When several of the commands land in the same phase, we need to order them
# deterministically.  This is meant to be temporary, until this code can be
# re-tooled to use `yum/dnf shell` to run all operations in one transaction.
PACMAN_COMMAND_ORDER = {
    cmd: i
    for i, cmd in enumerate(
        [
            # There's only one remove command, for now.
            PacmanCommand.remove_name_if_exists,
            PacmanCommand.local_install,
            PacmanCommand.install_name,
        ]
    )
}

assert len(PACMAN_COMMAND_ORDER) == len(PacmanCommand)


# The actual resolution is more complicated, see `_action_to_command()`
ACTION_TO_DEFAULT_CMD = {
    PacmanAction.install: PacmanAction.install_name,
    PacmanAction.remove_if_exists: PacmanAction.remove_name_if_exists,
}


class _LocalPackage(NamedTuple):
    path: Path


def _get_action_to_names_or_pkgs(
    items: Iterable["PacmanActionItem"],
) -> Mapping[PacmanAction, Union[str, _LocalPackage]]:
    action_to_names_or_pkgs = {action: set() for action in PacmanAction}
    for item in items:
        assert isinstance(item, PacmanActionItem), item

        # Eagerly resolve paths & metadata for local RPMs to avoid
        # repeating the required costly IO (or bug-prone implicit
        # memoization).
        if item.source is not None:
            path = item.source
            name_or_pkg = _LocalPackage(path=path)
        else:
            name_or_pkg = item.name

        action_to_names_or_pkgs[item.action].add(name_or_pkg)
    return action_to_names_or_pkgs


def _action_to_command(
    subvol: Subvol, action: PacmanAction, nor: Union[str, _LocalPackage]
) -> Tuple[PacmanCommand, Union[str, _LocalPackage]]:
    # Vanilla package name?
    if not isinstance(nor, _LocalPackage):
        return ACTION_TO_DEFAULT_CMD[action], nor
    # Local package?
    if action == PacmanAction.install:
        return PacmanCommand.local_install, nor
    # Bad PacmanAction?
    return None, None  # pragma: no cover


def _pkgs_and_bind_ros(
    names_or_pkgs: List[Union[str, _LocalPackage]]
) -> Tuple[List[str], List[str]]:
    pkgs = []
    bind_ros = []
    for idx, nor in enumerate(names_or_pkgs):
        if isinstance(nor, _LocalPackage):
            # For custom bind mount destinations, nspawn is strict on
            # destinations where the parent directories don't exist.
            # Because of that, we bind all the local pkgs in "/" with
            # uniquely prefix-ed names.
            dest = f"/localhostpkg_{idx}_{nor.path.basename()}"
            bind_ros.append((nor.path, dest))
            pkgs.append(dest)
        else:
            pkgs.append(nor)
    return pkgs, bind_ros


# These items are part of a phase, so they don't get dependency-sorted, so
# there is no `requires()` or `provides()` or `build()` method.
@dataclass(init=False, frozen=True)
class PacmanActionItem(ImageItem):
    action: PacmanAction
    name: Optional[str] = None
    source: Optional[str] = None
    version_set: Optional[Path] = None

    @classmethod
    def customize_fields(cls, kwargs):
        super().customize_fields(kwargs)
        assert (kwargs.get("name") is None) ^ (
            kwargs.get("source") is None
        ), f"Exactly one of `name` or `source` must be set in {kwargs}"
        kwargs["action"] = PacmanAction(kwargs["action"])

    def phase_order(self):
        return {
            PacmanAction.install: PhaseOrder.RPM_INSTALL,
            PacmanAction.remove_if_exists: PhaseOrder.RPM_REMOVE,
        }[self.action]

    @classmethod
    def get_phase_builder(
        cls, items: Iterable["PacmanActionItem"], layer_opts: LayerOpts
    ):
        # Do as much validation as possible outside of the builder to give
        # fast feedback to the user.
        build_appliance = layer_opts.requires_build_appliance()

        # This Mapping[PacmanAction, Union[str, _LocalPackage]] powers builder() below.
        action_to_names_or_pkgs = _get_action_to_names_or_pkgs(items)

        # Future: when we add per-layer version set overrides, they will
        # need apply on top of the repo-wide version set we are using.
        version_sets = set()
        for item in items:
            if item.version_set is None:
                continue
            version_sets.add(item.version_set)

        def builder(subvol: Subvol) -> None:
            with _prepare_versionlock(
                version_sets, layer_opts.version_set_override
            ) as versionlock_path:
                # Convert porcelain PacmanAction to plumbing PacmanCommands.  This
                # is done in the builder because we need access to the subvol.
                #
                # Sort by command for determinism and clearer behaivor.
                for cmd, nors in sorted(
                    _convert_actions_to_commands(
                        subvol, action_to_names_or_pkgs
                    ).items(),
                    key=lambda cn: PACMAN_COMMAND_ORDER[cn[0]],
                ):
                    pkgs, bind_ros = _pkgs_and_bind_ros(nors)
                    _pacman_using_build_appliance(
                        build_appliance=build_appliance,
                        bind_ros=bind_ros,
                        install_root=subvol.path(),
                        protected_paths=protected_path_set(subvol),
                        pacman_args=[
                            cmd.value,
                            "--noconfirm",
                            # Sort ensures determinism even if `yum` or
                            # `dnf` is order-dependent
                            *sorted(pkgs),
                        ],
                        layer_opts=layer_opts,
                    )

        return builder


def _default_snapshot(build_appliance: Subvol) -> Path:
    return (
        # The symlink is relative, but we need an absolute path.
        Path(RPM_DEFAULT_SNAPSHOT_FOR_INSTALLER_DIR)
        / os.readlink(
            build_appliance.path(RPM_DEFAULT_SNAPSHOT_FOR_INSTALLER_DIR / "pacman")
        )
    ).normpath()


def _pacman_using_build_appliance(
    *,
    build_appliance: Subvol,
    bind_ros: List[Tuple[str, str]],
    install_root: Path,
    protected_paths: Iterable[str],
    pacman_args: List[str],
    layer_opts: LayerOpts,
) -> None:
    work_dir = generate_work_dir()
    snapshot_dir = (
        layer_opts.rpm_repo_snapshot
        if layer_opts.rpm_repo_snapshot
        else _default_snapshot(build_appliance)
    )
    opts = new_nspawn_opts(
        cmd=[
            "sh",
            "-uec",
            f"""
            pacman \
            --config={(snapshot_dir / "pacman.conf").shell_quote()} \
            --root={work_dir} {
                ' '.join(shlex.quote(arg) for arg in pacman_args)
            }
            """,
        ],
        layer=build_appliance,
        bindmount_ro=bind_ros,
        bindmount_rw=[(install_root, work_dir)],
        user=pwd.getpwnam("root"),
    )
    run_nspawn(
        opts,
        PopenArgs(),
    )