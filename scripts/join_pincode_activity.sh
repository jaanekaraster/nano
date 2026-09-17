#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PINCODE_FILE="${1:-$ROOT/data/maharashtra_pincodes.geojson}"
COUNTS_FILE="${2:-$ROOT/data/udyam/pincode_nic_counts_general.parquet}"
OUTPUT_FILE="${3:-$ROOT/data/maharashtra_pincodes_activity.geojson}"
FEATURES_FILE="${OUTPUT_FILE}.features.json"

for command in duckdb jq; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Error: %s is required but was not found on PATH.\n' "$command" >&2
    exit 1
  fi
done

for file in "$PINCODE_FILE" "$COUNTS_FILE"; do
  if [[ ! -f "$file" ]]; then
    printf 'Error: input file was not found: %s\n' "$file" >&2
    exit 1
  fi
done

rm -f "$FEATURES_FILE"

duckdb -json <<SQL > "$FEATURES_FILE"
LOAD spatial;
WITH counts AS (
  SELECT
    pincode,
    list(
      json_object(
        'general_category', general_category,
        'activity_count', activity_count
      ) ORDER BY general_category
    ) AS category_data,
    CAST(SUM(activity_count) AS BIGINT) AS activity_total
  FROM read_parquet('$COUNTS_FILE')
  GROUP BY pincode
), pins AS (
  SELECT
    pincode,
    state,
    district,
    officename,
    officetype,
    orig_ogc_fid,
    geom
  FROM st_read('$PINCODE_FILE')
)
SELECT json_object(
  'type', 'Feature',
  'properties', json_object(
    'pincode', pins.pincode,
    'state', pins.state,
    'district', pins.district,
    'officename', pins.officename,
    'officetype', pins.officetype,
    'orig_ogc_fid', pins.orig_ogc_fid,
    'centroid_lon', ST_X(ST_Centroid(pins.geom)),
    'centroid_lat', ST_Y(ST_Centroid(pins.geom)),
    'activity_total', COALESCE(counts.activity_total, 0),
    'category_data', COALESCE(TO_JSON(counts.category_data), '[]'::JSON)
  ),
  'geometry', ST_AsGeoJSON(pins.geom)::JSON
) AS feature
FROM pins
LEFT JOIN counts ON TRY_CAST(pins.pincode AS BIGINT) = counts.pincode;
SQL

jq '{type: "FeatureCollection", name: "maharashtra_pincodes_activity", features: map(.feature)}' \
  "$FEATURES_FILE" > "$OUTPUT_FILE"
rm "$FEATURES_FILE"

feature_count=$(jq '.features | length' "$OUTPUT_FILE")
if [[ "$feature_count" -eq 0 ]]; then
  printf 'Error: generated GeoJSON contains no features.\n' >&2
  exit 1
fi

printf 'Created %s with %s pincode features.\n' "$OUTPUT_FILE" "$feature_count"
