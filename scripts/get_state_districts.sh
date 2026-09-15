#!/usr/bin/env bash
set -euo pipefail

SOURCE_URL="https://raw.githubusercontent.com/datta07/INDIAN-SHAPEFILES/master/INDIA/INDIA_DISTRICTS.geojson"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DATA_DIR="${DATA_DIR:-$ROOT/build/districts}"
SOURCE_FILE="$DATA_DIR/india_districts.geojson"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/data/districts}"

usage() {
  cat <<'EOF'
Usage: scripts/get_state_districts.sh "STATE NAME" [OUTPUT_DIR]

Downloads India's district boundaries, then writes two GeoParquet files for the
requested state:
  <state>_districts.geojson    Individual district boundaries
  <state>_boundary.geojson     One dissolved state boundary

Examples:
  scripts/get_state_districts.sh "MAHARASHTRA"
  scripts/get_state_districts.sh "Tamil Nadu" data/districts
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 1 || $# -gt 2 ]]; then
  usage
  [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && exit 0
  exit 2
fi

STATE="$1"
OUTPUT_DIR="${2:-$OUTPUT_DIR}"

for command in curl ogr2ogr ogrinfo; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Error: %s is required but was not found on PATH.\n' "$command" >&2
    exit 1
  fi
done

if [[ -z "$STATE" ]]; then
  printf 'Error: state name cannot be empty.\n' >&2
  exit 2
fi

mkdir -p "$DATA_DIR" "$OUTPUT_DIR"

if [[ ! -s "$SOURCE_FILE" ]]; then
  printf 'Downloading India district boundaries...\n'
  curl --fail --location --retry 3 --silent --show-error "$SOURCE_URL" -o "$SOURCE_FILE"
fi

if ! ogrinfo -ro -q "$SOURCE_FILE" >/dev/null 2>&1; then
  printf 'Error: downloaded source is not a readable vector dataset: %s\n' "$SOURCE_FILE" >&2
  exit 1
fi

slug=$(printf '%s' "$STATE" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//')
if [[ -z "$slug" ]]; then
  printf 'Error: state name does not produce a valid output filename.\n' >&2
  exit 2
fi

normalized_state=$(printf '%s' "$STATE" | tr '[:lower:]' '[:upper:]')
sql_state=$(printf '%s' "$normalized_state" | sed "s/'/''/g")
districts_output="$OUTPUT_DIR/${slug}_districts.geojson"
boundary_output="$OUTPUT_DIR/${slug}_boundary.geojson"
districts_layer="india_district"

where_clause="state = '$sql_state'"
if ! ogrinfo -ro -q -where "$where_clause" "$SOURCE_FILE" >/dev/null 2>&1; then
  printf 'Error: no districts found for state %q. Use the source state spelling, for example "MAHARASHTRA".\n' "$STATE" >&2
  exit 1
fi

rm -f "$districts_output" "$boundary_output"
printf 'Writing %s\n' "$districts_output"
ogr2ogr -f GeoJSON "$districts_output" "$SOURCE_FILE" \
  -where "$where_clause"

printf 'Writing %s\n' "$boundary_output"
ogr2ogr -f GeoJSON "$boundary_output" "$districts_output" \
  -dialect SQLite \
  -sql "SELECT ST_Union(geometry) AS geometry FROM $districts_layer" \
  -nln state_boundary

printf 'Created:\n  %s\n  %s\n' "$districts_output" "$boundary_output"
