#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec env SUITE_COMPARE_NAME=librga SUITE_COMPARE_LABEL=librga \
	REQUIRE_ARTIFACTS="${REQUIRE_ARTIFACTS:-1}" \
	bash "$TEST_DIR/suite-compare.sh" "$@"
