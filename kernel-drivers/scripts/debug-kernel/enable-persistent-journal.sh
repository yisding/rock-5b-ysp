#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run this with sudo: sudo $0" >&2
  exit 1
fi

conf=/etc/systemd/journald.conf
backup="/etc/systemd/journald.conf.codex-backup-$(date +%Y%m%d-%H%M%S)"

set_journal_key() {
  local key=$1
  local value=$2

  if grep -qE "^${key}=" "${conf}"; then
    sed -i -E "s|^${key}=.*|${key}=${value}|" "${conf}"
  else
    sed -i "/^\[Journal\]/a ${key}=${value}" "${conf}"
  fi
}

cp -a "${conf}" "${backup}"

install -d -o root -g systemd-journal -m 2755 /var/log.hdd/journal

if [[ -e /var/log/journal && ! -L /var/log/journal ]]; then
  echo "/var/log/journal exists and is not a symlink; leaving it untouched." >&2
  echo "Move it aside or merge it into /var/log.hdd/journal before rerunning." >&2
  exit 1
fi

ln -sfn /var/log.hdd/journal /var/log/journal

set_journal_key Storage persistent
set_journal_key SystemMaxUse 256M
set_journal_key SystemMaxFileSize 64M
set_journal_key MaxRetentionSec 1month

systemctl restart systemd-journald.service
journalctl --flush

echo "Backup written to: ${backup}"
echo
systemd-analyze cat-config systemd/journald.conf | grep -E '^(Storage|SystemMaxUse|SystemMaxFileSize|MaxRetentionSec)='
echo
journalctl --disk-usage
echo
journalctl --list-boots --no-pager
