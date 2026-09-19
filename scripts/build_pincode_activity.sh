#!/usr/bin/env bash
set -euo pipefail

# Build a compact pincode activity JSON file from the large
# maharashtra_pincodes_activity.geojson.
#
# Requirements:
# - bash
# - jq
#
# Usage:
# ./scripts/build_pincode_activity.sh
#
# Input:
# data/maharashtra_pincodes_activity.geojson
#
# Output:
# data/pincode_activity.json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

INPUT="$REPO_ROOT/data/maharashtra_pincodes_activity.geojson"
OUTPUT="$REPO_ROOT/data/pincode_activity.json"
TMP_OUTPUT="${OUTPUT}.tmp"

echo "Building compact pincode activity data..."
echo

# ------------------------------------------------------------
# Checks
# ------------------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is not installed."
    echo
    echo "Install it with:"
    echo "  sudo apt install jq"
    exit 1
fi

echo "jq version:"
jq --version
echo

if [[ ! -f "$INPUT" ]]; then
    echo "ERROR: Input file not found:"
    echo "  $INPUT"
    exit 1
fi

echo "Input:"
echo "  $INPUT"
echo

# ------------------------------------------------------------
# Transform GeoJSON -> compact activity JSON
# ------------------------------------------------------------

jq '
def category_id:
{
    "A. Agriculture, Forestry & Fishing": "A",
    "B. Mining & Quarrying": "B",
    "C. Manufacturing": "C",
    "D_E. Electricity, Gas, Water & Waste": "DE",
    "F. Construction": "F",
    "G. Wholesale & Retail Trade": "G",
    "H. Transportation & Storage": "H",
    "I. Accommodation & Food Services": "I",
    "J. Information & Communication": "J",
    "K. Financial & Insurance": "K",
    "L. Real Estate": "L",
    "M. Professional, Scientific & Technical": "M",
    "N. Administrative & Support Services": "N",
    "O. Public Administration & Defence": "O",
    "P. Education": "P",
    "Q. Human Health & Social Work": "Q",
    "R. Arts, Entertainment & Recreation": "R",
    "S. Other Service Activities": "S"
}[.];

def parsed_category_data:
    if type == "string"
    then fromjson
    else .
    end;

reduce .features[] as $feature
    ( {};

      ($feature.properties) as $p |
      ($p.pincode | tostring) as $pincode |

      if ($pincode == "null" or $pincode == "") then
          .
      else
          .[$pincode] = {
              lon: ($p.centroid_lon | tonumber),
              lat: ($p.centroid_lat | tonumber),
              total: ($p.activity_total | tonumber),

              categories:
                  (
                      ($p.category_data | parsed_category_data)
                      | map({
                          key: (.general_category | category_id),
                          value: (.activity_count | tonumber)
                        })
                      | from_entries
                  )
          }
      end
    )
' "$INPUT" > "$TMP_OUTPUT"

# ------------------------------------------------------------
# Validate generated JSON
# ------------------------------------------------------------

echo
echo "Validating generated JSON..."

if ! jq empty "$TMP_OUTPUT" >/dev/null 2>&1; then
    echo "ERROR: Generated JSON is invalid."
    rm -f "$TMP_OUTPUT"
    exit 1
fi

PINCODE_COUNT="$(jq 'length' "$TMP_OUTPUT")"

if [[ "$PINCODE_COUNT" -eq 0 ]]; then
    echo "ERROR: Generated JSON contains zero pincodes."
    rm -f "$TMP_OUTPUT"
    exit 1
fi

INVALID_COUNT="$(
    jq '
    [
        to_entries[]
        | select(
            .value.lon == null
            or .value.lat == null
            or .value.total == null
        )
    ]
    | length
    ' "$TMP_OUTPUT"
)"

if [[ "$INVALID_COUNT" -gt 0 ]]; then
    echo "ERROR: $INVALID_COUNT pincodes have missing coordinates or totals."
    rm -f "$TMP_OUTPUT"
    exit 1
fi

# ------------------------------------------------------------
# Install output
# ------------------------------------------------------------

mv "$TMP_OUTPUT" "$OUTPUT"

# ------------------------------------------------------------
# Report
# ------------------------------------------------------------

INPUT_BYTES="$(wc -c < "$INPUT")"
OUTPUT_BYTES="$(wc -c < "$OUTPUT")"

INPUT_MB="$(awk "BEGIN {printf \"%.2f\", $INPUT_BYTES / 1048576}")"
OUTPUT_MB="$(awk "BEGIN {printf \"%.2f\", $OUTPUT_BYTES / 1048576}")"

REDUCTION="$(
    awk "BEGIN {
        printf \"%.1f\", (1 - $OUTPUT_BYTES / $INPUT_BYTES) * 100
    }"
)"

echo
echo "Done."
echo
echo "Input:"
echo "  $INPUT"
echo "  ${INPUT_MB} MB"
echo
echo "Output:"
echo "  $OUTPUT"
echo "  ${OUTPUT_MB} MB"
echo
echo "Pincodes:"
echo "  $PINCODE_COUNT"
echo
echo "Size reduction:"
echo "  ${REDUCTION}%"
echo
echo "Example record:"
jq 'to_entries[0]' "$OUTPUT"
echo
echo "Output is valid JSON."