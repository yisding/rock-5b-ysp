#!/usr/bin/env bash

set -euo pipefail

readonly UBOOT_OFFSET_BYTES=$((16384 * 512))
readonly UBOOT_WINDOW_BYTES=$((4 * 1024 * 1024))

usage() {
	cat <<'EOF'
Usage: audit-armbian-rockchip-fit.sh IMAGE_URL [OUTPUT_FILE]

Stream the beginning of an xz-compressed Armbian image, extract the raw
U-Boot FIT written at sector 16384, and report whether any Flat Device Tree
component has a zero-byte payload. The full OS image is not downloaded or
retained.

OUTPUT_FILE defaults to a temporary file under the current directory and is
removed after inspection.
EOF
}

if (( $# < 1 || $# > 2 )); then
	usage >&2
	exit 2
fi

for command in curl xz dd dumpimage awk; do
	command -v "${command}" >/dev/null || {
		echo "error: required command not found: ${command}" >&2
		exit 2
	}
done

readonly image_url=$1
keep_output=false
if (( $# == 2 )); then
	output_file=$2
	keep_output=true
else
	output_file=$(mktemp --tmpdir=. armbian-u-boot-fit.XXXXXX)
fi

cleanup() {
	if [[ ${keep_output} == false ]]; then
		rm -f -- "${output_file}"
	fi
}
trap cleanup EXIT

# dd stops after the FIT-sized window, which closes the pipeline early. curl
# and xz therefore normally report a broken pipe; PIPESTATUS[2] is the status
# that matters here.
set +e
curl -fLs --write-out '%{stderr}STREAMED_COMPRESSED_BYTES: %{size_download}\n' "${image_url}" \
	| xz --decompress --stdout 2>/dev/null \
	| dd of="${output_file}" iflag=skip_bytes,count_bytes \
		skip="${UBOOT_OFFSET_BYTES}" count="${UBOOT_WINDOW_BYTES}" status=none
pipeline_status=("${PIPESTATUS[@]}")
set -e

if (( pipeline_status[2] != 0 )); then
	echo "error: failed to extract the U-Boot window (dd status ${pipeline_status[2]})" >&2
	exit 1
fi

actual_size=$(stat -c %s "${output_file}")
if (( actual_size != UBOOT_WINDOW_BYTES )); then
	echo "error: extracted ${actual_size} bytes; expected ${UBOOT_WINDOW_BYTES}" >&2
	exit 1
fi

listing=$(dumpimage -l "${output_file}") || {
	echo "error: no readable U-Boot FIT at raw image offset ${UBOOT_OFFSET_BYTES}" >&2
	exit 1
}

printf '%s\n' "${listing}"

mapfile -t fdt_sizes < <(awk '
	/^ Image [0-9]+ / { in_fdt = 0 }
	/^  Type:[[:space:]]+Flat Device Tree$/ { in_fdt = 1; next }
	in_fdt && /^  Data Size:/ { print $3; in_fdt = 0 }
' <<<"${listing}")

if (( ${#fdt_sizes[@]} == 0 )); then
	echo "RESULT: INDETERMINATE (FIT has no Flat Device Tree component)"
	exit 11
fi

for fdt_size in "${fdt_sizes[@]}"; do
	if [[ ! ${fdt_size} =~ ^[0-9]+$ ]]; then
		echo "RESULT: INDETERMINATE (could not parse FIT fdt size: ${fdt_size})"
		exit 11
	fi
done

(
	IFS=,
	echo "FDT_SIZE_BYTES: ${fdt_sizes[*]}"
)

for fdt_size in "${fdt_sizes[@]}"; do
	if (( fdt_size == 0 )); then
		echo "RESULT: BROKEN (FIT contains a zero-byte Flat Device Tree component)"
		exit 10
	fi
done

echo "RESULT: OK (all FIT Flat Device Tree components are nonzero)"
