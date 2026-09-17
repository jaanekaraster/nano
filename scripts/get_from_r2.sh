#!/usr/bin/env bash

set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-r2}"
R2_BUCKET="${R2_BUCKET:-geodata-lake}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAW_DIR="${REPO_ROOT}/data/raw"

usage() {
    cat <<'EOF'
Usage: scripts/get_from_r2.sh <r2-filepath>

Downloads an object from the configured R2 bucket into data/raw/.
The output filename is taken from the final component of the R2 filepath.

Environment variables:
  AWS_PROFILE  AWS CLI profile to use (default: r2)
  R2_BUCKET    R2 bucket name (default: geodata-lake)

Example:
  scripts/get_from_r2.sh geotiff/built_s_2025.tif
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ $# -ne 1 ]]; then
    usage >&2
    exit 2
fi

R2_KEY="$1"
OUTPUT_FILE="${RAW_DIR}/$(basename -- "$R2_KEY")"
R2_URI="s3://${R2_BUCKET}/${R2_KEY}"

if [[ -z "$R2_KEY" || "$(basename -- "$R2_KEY")" == "." || "$(basename -- "$R2_KEY")" == "/" ]]; then
    printf 'Error: R2 filepath cannot be empty or end in a directory.\n' >&2
    exit 2
fi

if ! command -v aws >/dev/null 2>&1; then
    printf 'Error: aws is required but was not found on PATH.\n' >&2
    exit 1
fi

mkdir -p "$RAW_DIR"

printf 'Checking R2 object...\n'
aws --profile "$AWS_PROFILE" s3api head-object \
    --bucket "$R2_BUCKET" \
    --key "$R2_KEY" \
    >/dev/null

printf 'Downloading %s\n' "$R2_URI"
aws --profile "$AWS_PROFILE" s3 cp "$R2_URI" "$OUTPUT_FILE"

printf '\nDownload complete:\n%s\n' "$OUTPUT_FILE"
ls -lh "$OUTPUT_FILE"
