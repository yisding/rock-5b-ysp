#!/usr/bin/env bash
# =============================================================================
# install-debug-kernel.sh -- compatibility shim.
#
# Superseded by ../install-kernel.sh (see install-combined-kernel.sh for why the
# two installers merged). Everything this script used to do is now unconditional
# there -- including the load-address preflight, which is what stops an
# oversized KASAN Image from clearing its BSS over the device tree and dying
# before console init.
#
# Forwards to install-kernel.sh, which infers the slot from PHASH -- so this
# name no longer pins a flavor, it just installs the build you named.
#
#   sudo RECOVERY_READY=1 PHASH='P####-C####' bash install-debug-kernel.sh
# =============================================================================
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$HERE/../install-kernel.sh" "$@"
