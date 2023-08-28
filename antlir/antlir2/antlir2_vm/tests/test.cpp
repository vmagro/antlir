/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#include <gtest/gtest.h>
#include <unistd.h>

TEST(CppTest, TestIsRoot) {
  EXPECT_EQ(getuid(), 0);
}

TEST(CppTest, TestEnvPropagated) {
  ASSERT_STREQ(std::getenv("ANTLIR2_TEST"), "1");
}