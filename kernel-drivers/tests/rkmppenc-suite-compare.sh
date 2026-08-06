#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec env SUITE_COMPARE_NAME=rkmppenc SUITE_COMPARE_LABEL=rkmppenc \
	REQUIRE_ARTIFACTS="${REQUIRE_ARTIFACTS:-1}" \
	bash "$TEST_DIR/suite-compare.sh" "$@"
