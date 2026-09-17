#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAW_DIR="${REPO_ROOT}/data/raw"
PROCESSED_DIR="${REPO_ROOT}/data/processed"
DEFAULT_CUTLINE="${REPO_ROOT}/data/districts/maharashtra_boundary.geojson"

usage() {
    cat <<'EOF'
Usage: scripts/clip_downloaded_file.sh <filename> [geojson-path]

Clips data/raw/<filename> to a GeoJSON boundary and writes the result to
data/processed/<filename>. The raw input is removed only after a successful
clip.

The GeoJSON path may be absolute, relative to the current directory, or
relative to data/. If omitted, Maharashtra's dissolved boundary is used.

Example:
  scripts/clip_downloaded_file.sh built_s_2025.tif districts/maharashtra_boundary.geojson
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage >&2
    exit 2
fi

FILENAME="$1"
INPUT_FILE="${RAW_DIR}/${FILENAME}"
OUTPUT_FILE="${PROCESSED_DIR}/${FILENAME}"
CUTLINE_PATH="${2:-$DEFAULT_CUTLINE}"

if [[ "$CUTLINE_PATH" != /* && ! -f "$CUTLINE_PATH" ]]; then
    if [[ -f "${REPO_ROOT}/data/${CUTLINE_PATH}" ]]; then
        CUTLINE_PATH="${REPO_ROOT}/data/${CUTLINE_PATH}"
    fi
fi

if [[ ! -f "$INPUT_FILE" ]]; then
    printf 'Error: input file was not found: %s\n' "$INPUT_FILE" >&2
    exit 1
fi

if [[ ! -f "$CUTLINE_PATH" ]]; then
    printf 'Error: GeoJSON cutline was not found: %s\n' "$CUTLINE_PATH" >&2
    exit 1
fi

if ! command -v gdalwarp >/dev/null 2>&1; then
    printf 'Error: gdalwarp is required but was not found on PATH.\n' >&2
    exit 1
fi

mkdir -p "$PROCESSED_DIR"
TEMP_OUTPUT="${OUTPUT_FILE}.tmp.tif"
rm -f "$TEMP_OUTPUT"

printf 'Clipping %s\n' "$INPUT_FILE"
printf 'Boundary: %s\n' "$CUTLINE_PATH"
printf 'Output: %s\n' "$OUTPUT_FILE"

gdalwarp \
    "$INPUT_FILE" \
    "$TEMP_OUTPUT" \
    -cutline "$CUTLINE_PATH" \
    -crop_to_cutline \
    -dstalpha \
    -of GTiff \
    -co TILED=YES \
    -co COMPRESS=DEFLATE

mv "$TEMP_OUTPUT" "$OUTPUT_FILE"
rm "$INPUT_FILE"

printf '\nClip complete:\n%s\n' "$OUTPUT_FILE"
ls -lh "$OUTPUT_FILE"
