#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INPUT_FILE="${1:-$ROOT/data/udyam/pincode_nic_counts.parquet}"
OUTPUT_FILE="${2:-$ROOT/data/udyam/pincode_nic_counts_general.parquet}"
TEMP_FILE="${OUTPUT_FILE}.tmp.parquet"

if ! command -v duckdb >/dev/null 2>&1; then
  printf 'Error: duckdb is required but was not found on PATH.\n' >&2
  exit 1
fi

if [[ ! -f "$INPUT_FILE" ]]; then
  printf 'Error: input Parquet was not found: %s\n' "$INPUT_FILE" >&2
  exit 1
fi

rm -f "$TEMP_FILE"

duckdb <<SQL
COPY (
  SELECT
    pincode,
    general_category,
    CAST(SUM(activity_count) AS BIGINT) AS activity_count
  FROM read_parquet('$INPUT_FILE')
  GROUP BY pincode, general_category
  ORDER BY pincode, general_category
) TO '$TEMP_FILE' (FORMAT PARQUET);
SQL

IFS=, read -r ROW_COUNT NULL_CATEGORIES < <(
duckdb -noheader -csv -c "SELECT COUNT(*), COUNT(*) FILTER (WHERE general_category IS NULL) FROM read_parquet('$TEMP_FILE');"
)

if [[ "$ROW_COUNT" -eq 0 || "$NULL_CATEGORIES" -ne 0 ]]; then
  printf 'Error: generated Parquet failed validation.\n' >&2
  rm -f "$TEMP_FILE"
  exit 1
fi

mv "$TEMP_FILE" "$OUTPUT_FILE"
printf 'Created %s: %s pincode/category rows.\n' "$OUTPUT_FILE" "$ROW_COUNT"
