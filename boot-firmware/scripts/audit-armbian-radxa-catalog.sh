#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
readonly FIT_AUDITOR="${SCRIPT_DIR}/audit-armbian-rockchip-fit.sh"

usage() {
	cat <<'EOF'
Usage: audit-armbian-radxa-catalog.sh BOARD_SLUG [BOARD_SLUG ...]

Read each board's current Armbian download catalog and audit every linked
image with the prefix-only Rockchip FIT checker. Results are emitted as TSV.

BOARD_SLUG is the final component of any Armbian board-page URL, for example
rock-5b, radxa-zero3, or orangepi5-plus. The historical script name does not
restrict it to Radxa-branded boards.
EOF
}

if (( $# == 0 )); then
	usage >&2
	exit 2
fi

for command in curl rg sed sort awk; do
	command -v "${command}" >/dev/null || {
		echo "error: required command not found: ${command}" >&2
		exit 2
	}
done

[[ -x ${FIT_AUDITOR} ]] || {
	echo "error: FIT auditor is not executable: ${FIT_AUDITOR}" >&2
	exit 2
}

printf 'board\tstatus\tfdt_bytes\tfit_created\tstreamed_compressed_bytes\tsha256\timage\talias\n'

declare -i errors=0

for board in "$@"; do
	board_page="https://armbian.com/boards/${board}"
	echo "catalog: ${board_page}" >&2
	page=$(curl -fLs "${board_page}")

	mapfile -t image_urls < <(
		printf '%s' "${page}" \
			| rg -o 'href="https://dl\.armbian\.com/[^"]+"' \
			| sed 's/^href="//; s/"$//' \
			| rg -v '\.(sha|asc|torrent)$' \
			| sort -u
	)

	if (( ${#image_urls[@]} == 0 )); then
		echo "warning: no image links found for ${board}" >&2
		((errors += 1))
		continue
	fi

	for image_url in "${image_urls[@]}"; do
		alias_name=${image_url#https://dl.armbian.com/}
		echo "audit: ${alias_name}" >&2

		checksum_line=$(curl -fLs "${image_url}.sha" || true)
		image_sha=${checksum_line%%[[:space:]]*}
		image_name=${checksum_line#*[[:space:]]}
		if [[ -z ${checksum_line} || ${image_name} == "${checksum_line}" ]]; then
			image_sha="-"
			image_name=${image_url##*/}
		fi

		set +e
		audit_output=$("${FIT_AUDITOR}" "${image_url}" 2>&1)
		audit_rc=$?
		set -e

		case ${audit_rc} in
			0) status=CLEAN ;;
			10) status=BROKEN ;;
			11) status=INDETERMINATE ;;
			*)
				status=ERROR
				((errors += 1))
				;;
		esac

		fdt_size=$(awk '/^FDT_SIZE_BYTES:/ { print $2; exit }' <<<"${audit_output}")
		fit_created=$(sed -n 's/^Created:[[:space:]]*//p' <<<"${audit_output}" | head -n 1)
		streamed_bytes=$(awk '/^STREAMED_COMPRESSED_BYTES:/ { print $2; exit }' <<<"${audit_output}")
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"${board}" "${status}" "${fdt_size:--}" "${fit_created:--}" \
			"${streamed_bytes:--}" "${image_sha}" "${image_name}" "${alias_name}"

		if [[ ${status} == ERROR ]]; then
			printf '%s\n' "${audit_output}" >&2
		fi
	done
done

(( errors == 0 ))
