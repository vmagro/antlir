#!/usr/bin/env python3
# Copyright (c) Facebook, Inc. and its affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

import time
import unittest


class VmtestKernelPanic(unittest.TestCase):
    def test_trigger_kernel_panic(self):
        with open("/proc/sysrq-trigger", "w") as f:
            f.write("c")
        while True:
            # Wait for kernel panic to stop us
            time.sleep(0)
