#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INPUT_FILE="${1:-$ROOT/data/udyam/pincode_nic_counts.parquet}"
TEMP_FILE="${INPUT_FILE}.tmp.parquet"

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
    nic5_id,
    activity_count,
    CASE
      WHEN try_cast(substr(nic5_id, 1, 2) AS INTEGER) BETWEEN 1 AND 3 THEN 'A. Agriculture, Forestry & Fishing'
      WHEN try_cast(substr(nic5_id, 1, 2) AS INTEGER) BETWEEN 5 AND 9 THEN 'B. Mining & Quarrying'
      WHEN try_cast(substr(nic5_id, 1, 2) AS INTEGER) BETWEEN 10 AND 33 THEN 'C. Manufacturing'
      WHEN try_cast(substr(nic5_id, 1, 2) AS INTEGER) BETWEEN 35 AND 39 THEN 'D_E. Electricity, Gas, Water & Waste'
      WHEN try_cast(substr(nic5_id, 1, 2) AS INTEGER) BETWEEN 41 AND 43 THEN 'F. Construction'
      WHEN try_cast(substr(nic5_id, 1, 2) AS INTEGER) BETWEEN 45 AND 47 THEN 'G. Wholesale & Retail Trade'
      WHEN try_cast(substr(nic5_id, 1, 2) AS INTEGER) BETWEEN 49 AND 53 THEN 'H. Transportation & Storage'
      WHEN try_cast(substr(nic5_id, 1, 2) AS INTEGER) BETWEEN 55 AND 56 THEN 'I. Accommodation & Food Services'
      WHEN try_cast(substr(nic5_id, 1, 2) AS INTEGER) BETWEEN 58 AND 63 THEN 'J. Information & Communication'
      WHEN try_cast(substr(nic5_id, 1, 2) AS INTEGER) BETWEEN 64 AND 66 THEN 'K. Financial & Insurance'
      WHEN try_cast(substr(nic5_id, 1, 2) AS INTEGER) = 68 THEN 'L. Real Estate'
      WHEN try_cast(substr(nic5_id, 1, 2) AS INTEGER) BETWEEN 69 AND 75 THEN 'M. Professional, Scientific & Technical'
      WHEN try_cast(substr(nic5_id, 1, 2) AS INTEGER) BETWEEN 77 AND 82 THEN 'N. Administrative & Support Services'
      WHEN try_cast(substr(nic5_id, 1, 2) AS INTEGER) = 84 THEN 'O. Public Administration & Defence'
      WHEN try_cast(substr(nic5_id, 1, 2) AS INTEGER) = 85 THEN 'P. Education'
      WHEN try_cast(substr(nic5_id, 1, 2) AS INTEGER) BETWEEN 86 AND 88 THEN 'Q. Human Health & Social Work'
      WHEN try_cast(substr(nic5_id, 1, 2) AS INTEGER) BETWEEN 90 AND 93 THEN 'R. Arts, Entertainment & Recreation'
      WHEN try_cast(substr(nic5_id, 1, 2) AS INTEGER) BETWEEN 94 AND 96 THEN 'S. Other Service Activities'
      WHEN try_cast(substr(nic5_id, 1, 2) AS INTEGER) BETWEEN 97 AND 98 THEN 'T. Households as Employers'
      WHEN try_cast(substr(nic5_id, 1, 2) AS INTEGER) = 99 THEN 'U. Extraterritorial Organizations'
      ELSE 'X. Unclassified'
    END AS general_category
  FROM read_parquet('$INPUT_FILE')
) TO '$TEMP_FILE' (FORMAT PARQUET);
SQL

IFS=, read -r ROW_COUNT CATEGORY_COUNT < <(
duckdb -noheader -csv -c "SELECT COUNT(*), COUNT(DISTINCT general_category) FROM read_parquet('$TEMP_FILE');"
)

if [[ "$ROW_COUNT" -eq 0 || "$CATEGORY_COUNT" -eq 0 ]]; then
  printf 'Error: generated Parquet failed validation.\n' >&2
  rm -f "$TEMP_FILE"
  exit 1
fi

mv "$TEMP_FILE" "$INPUT_FILE"
printf 'Updated %s: %s rows across %s categories.\n' "$INPUT_FILE" "$ROW_COUNT" "$CATEGORY_COUNT"
