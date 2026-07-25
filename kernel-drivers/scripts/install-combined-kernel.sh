#!/usr/bin/env bash
# =============================================================================
# install-combined-kernel.sh -- compatibility shim.
#
# The production and debug installers were unified into install-kernel.sh once
# per-flavor package slots made them the same script with a different SLOT: the
# U-Boot load-address preflight (previously debug-only) and the obsolete
# rkvdec2 overlay removal (previously production-only) both apply to every
# kernel this repo builds, so neither is conditional any more.
#
# This name is kept because install.md, the validation runbook, the READMEs and
# dated findings all cite it. It forwards to install-kernel.sh with the
# production forward-port slot; override with SLOT= as before.
#
#   sudo RECOVERY_READY=1 PHASH='P####-C####' bash install-combined-kernel.sh
# =============================================================================
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$HERE/install-kernel.sh" "$@"
