#!/bin/bash
# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

set -ex

if [ -f "/is-facebook" ]; then
    if [ -L ".eden/root" ]; then
        echo "in repo" > /status
    else
        echo "not in repo" > /status
    fi
else
    if [ -d ".git" ]; then
        echo "in repo" > /status
    elif [ -d ".hg" ]; then
        echo "in repo" > /status
    elif [ -d ".sl" ]; then
        echo "in repo" > /status
    else
        echo "not in repo" > /status
    fi
fi
