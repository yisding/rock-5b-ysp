#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec env SUITE_COMPARE_NAME=ffmpeg SUITE_COMPARE_LABEL=FFmpeg \
	REQUIRE_ARTIFACTS="${REQUIRE_ARTIFACTS:-1}" \
	bash "$TEST_DIR/suite-compare.sh" "$@"
