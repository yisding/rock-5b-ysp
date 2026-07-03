#!/usr/bin/env bash
# Shared helpers for collecting simple numeric debugfs counters.

debugfs_counter_snapshot()
{
	local output=$1
	local component
	local dir
	local file
	local name
	local value

	shift
	printf "component\tcounter\tvalue\n" > "$output"

	while [ "$#" -gt 0 ]; do
		component=$1
		dir=$2
		shift 2

		[ -d "$dir" ] || continue

		while IFS= read -r file; do
			name=$(basename "$file")
			value=$(cat "$file" 2>/dev/null || true)
			value=${value//$'\n'/}
			value=${value//$'\r'/}
			value=${value//[[:space:]]/}

			case "$value" in
			''|*[!0-9-]*)
				continue
				;;
			esac

			printf "%s\t%s\t%s\n" "$component" "$name" "$value" >> "$output"
		done < <(find "$dir" -maxdepth 1 -type f -print 2>/dev/null | sort)
	done
}

debugfs_counter_delta()
{
	local before=$1
	local after=$2
	local output=$3

	awk '
	BEGIN {
		FS = OFS = "\t";
		print "component", "counter", "before", "after", "delta";
	}

	FNR == 1 {
		next;
	}

	FILENAME == before_file {
		key = $1 SUBSEP $2;
		before[key] = $3;
		component[key] = $1;
		counter[key] = $2;
		next;
	}

	FILENAME == after_file {
		key = $1 SUBSEP $2;
		seen_after[key] = 1;
		component[key] = $1;
		counter[key] = $2;
		after_value = $3;
		before_value = (key in before) ? before[key] : "";
		delta = (before_value != "" && after_value ~ /^-?[0-9]+$/ &&
			 before_value ~ /^-?[0-9]+$/) ? after_value - before_value : "";
		print $1, $2, before_value, after_value, delta;
		next;
	}

	END {
		for (key in before) {
			if (key in seen_after)
				continue;
			print component[key], counter[key], before[key], "", "";
		}
	}
	' before_file="$before" after_file="$after" "$before" "$after" > "$output"
}
