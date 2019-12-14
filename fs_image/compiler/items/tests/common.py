#!/usr/bin/env python3
import os
import tempfile
import unittest

from contextlib import contextmanager

from btrfs_diff.tests.render_subvols import render_sendstream
from compiler.provides import ProvidesDirectory, ProvidesFile

from ..common import LayerOpts

DEFAULT_STAT_OPTS = ['--user=root', '--group=root', '--mode=0755']
DUMMY_LAYER_OPTS = LayerOpts(
    layer_target='fake target',  # Only used by error messages
    build_appliance=None,
    # For a handful of tests, this must be a boolean value so the layer
    # emits it it into /meta, but the value is not important.
    artifacts_may_require_repo=True,
    target_to_path=None,
    subvolumes_dir=None,
    preserve_yum_cache=False,
)


def render_subvol(subvol: {'Subvol'}):
    rendered = render_sendstream(subvol.mark_readonly_and_get_sendstream())
    subvol.set_readonly(False)  # YES, all our subvolumes are read-write.
    return rendered


def populate_temp_filesystem(img_path):
    'Matching Provides are generated by _temp_filesystem_provides'

    def p(img_rel_path):
        return os.path.join(img_path, img_rel_path)

    os.makedirs(p('a/b/c'))
    os.makedirs(p('a/d'))

    for filepath in ['a/E', 'a/d/F', 'a/b/c/G']:
        with open(p(filepath), 'w') as f:
            f.write('Hello, ' + filepath)


@contextmanager
def temp_filesystem():
    with tempfile.TemporaryDirectory() as td_path:
        populate_temp_filesystem(td_path)
        yield td_path


def temp_filesystem_provides(p=''):
    'Captures what is provided by _temp_filesystem, if installed at `p` '
    'inside the image.'
    return {
        ProvidesDirectory(path=f'{p}/a'),
        ProvidesDirectory(path=f'{p}/a/b'),
        ProvidesDirectory(path=f'{p}/a/b/c'),
        ProvidesDirectory(path=f'{p}/a/d'),
        ProvidesFile(path=f'{p}/a/E'),
        ProvidesFile(path=f'{p}/a/d/F'),
        ProvidesFile(path=f'{p}/a/b/c/G'),
    }


class BaseItemTestCase(unittest.TestCase):

    def setUp(self):  # More output for easier debugging
        unittest.util._MAX_LENGTH = 12345
        self.maxDiff = 12345

    def _check_item(self, i, provides, requires):
        self.assertEqual(provides, set(i.provides()))
        self.assertEqual(requires, set(i.requires()))
