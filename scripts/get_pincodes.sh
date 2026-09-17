#!/usr/bin/env bash

set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-r2}"
R2_BUCKET="${R2_BUCKET:-geodata-lake}"
R2_PREFIX="${R2_PREFIX:-pincodes}"

# get_pincodes.sh lives in:
#
#   myrepo/scripts/get_pincodes.sh
#
# So the repository root is one directory above the script.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DATA_DIR="${REPO_ROOT}/data"


if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <state>"
    echo
    echo "Example:"
    echo "  $0 maharashtra"
    exit 1
fi


STATE="$1"

STATE_SLUG="$(
    echo "${STATE}" |
    tr '[:upper:]' '[:lower:]' |
    tr ' ' '_' |
    tr -cd '[:alnum:]_-'
)"

R2_KEY="${R2_PREFIX}/${STATE_SLUG}.geojson"
R2_URI="s3://${R2_BUCKET}/${R2_KEY}"

OUTPUT_FILE="${DATA_DIR}/${STATE_SLUG}.geojson"


echo
echo "Downloading pincode data"
echo "------------------------"
echo "Source : ${R2_URI}"
echo "Output : ${OUTPUT_FILE}"
echo


mkdir -p "${DATA_DIR}"


echo "Checking R2 object..."

aws \
    --profile "${AWS_PROFILE}" \
    s3api head-object \
    --bucket "${R2_BUCKET}" \
    --key "${R2_KEY}" \
    >/dev/null


echo "Downloading..."

aws \
    --profile "${AWS_PROFILE}" \
    s3 cp \
    "${R2_URI}" \
    "${OUTPUT_FILE}"


echo
echo "✓ Download complete"
echo
echo "File:"
ls -lh "${OUTPUT_FILE}"
echo