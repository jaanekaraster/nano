#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUILD_DIR="$ROOT/build/pmtiles"
INPUT_DIR="$ROOT/data/processed/clipped"
OUTPUT_DIR="$ROOT/data/processed/pmtiles"
PMTILES_BIN="${PMTILES_BIN:-pmtiles}"
if ! command -v "$PMTILES_BIN" >/dev/null 2>&1 && [[ -x "$HOME/.local/bin/pmtiles" ]]; then
  PMTILES_BIN="$HOME/.local/bin/pmtiles"
fi
TARGET_ZOOM="${TARGET_ZOOM:-6}"
TARGET_RESOLUTION=$(awk -v zoom="$TARGET_ZOOM" 'BEGIN { printf "%.12f", 156543.03392804097 / (2 ^ zoom) }')
DETAIL_ZOOM="${DETAIL_ZOOM:-11}"
DETAIL_RESOLUTION=$(awk -v zoom="$DETAIL_ZOOM" 'BEGIN { printf "%.12f", 156543.03392804097 / (2 ^ zoom) }')
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

build_raster() {
  local id="$1"
  local input="$2"
  local min_value="$3"
  local max_value="$4"
  local red="$5"
  local green="$6"
  local blue="$7"
  local title="$8"
  local description="$9"
  local mode="${10:-sequential}"
  local ramp="$BUILD_DIR/${id}.txt"
  local colorized="$BUILD_DIR/${id}_color.tif"
  local projected="$BUILD_DIR/${id}_3857_overview.tif"
  local detailed_projected="$BUILD_DIR/${id}_3857_detail.tif"
  local mbtiles="$BUILD_DIR/${id}_overview.mbtiles"
  local detailed_mbtiles="$BUILD_DIR/${id}_detail.mbtiles"
  local overview_pmtiles="$BUILD_DIR/${id}_overview.pmtiles"
  local detailed_pmtiles="$BUILD_DIR/${id}_detail.pmtiles"
  local metadata_json="$BUILD_DIR/${id}_metadata.json"
  local pmtiles="$OUTPUT_DIR/${id}.pmtiles"

  rm -f "$ramp" "$colorized" "$projected" "$detailed_projected" "$mbtiles" "$detailed_mbtiles" "$overview_pmtiles" "$detailed_pmtiles" "$metadata_json" "$pmtiles"

  if [[ "$mode" == "diverging" ]]; then
    printf '%s\n' \
      'nv 255 255 255 0' \
      "$min_value 165 15 21 235" \
      "0 255 255 255 0" \
      "$max_value 118 42 131 235" > "$ramp"
  else
    printf '%s\n' \
      'nv 255 255 255 0' \
      "$min_value $red $green $blue 0" \
      "$max_value $red $green $blue 255" > "$ramp"
  fi

  gdaldem color-relief "$INPUT_DIR/$input" "$ramp" "$colorized" \
    -alpha -of GTiff -co TILED=YES -co COMPRESS=DEFLATE
  gdalwarp "$colorized" "$projected" -t_srs EPSG:3857 -r bilinear \
    -tr "$TARGET_RESOLUTION" "$TARGET_RESOLUTION" \
    -dstalpha -of GTiff -co TILED=YES -co COMPRESS=DEFLATE
  gdal_translate "$projected" "$mbtiles" -of MBTiles \
    -co TILE_FORMAT=PNG -co MINZOOM="$TARGET_ZOOM" -co MAXZOOM="$TARGET_ZOOM" \
    -co NAME="$title" -co DESCRIPTION="$description"
  gdalwarp "$colorized" "$detailed_projected" -t_srs EPSG:3857 -r bilinear \
    -tr "$DETAIL_RESOLUTION" "$DETAIL_RESOLUTION" \
    -dstalpha -of GTiff -co TILED=YES -co COMPRESS=DEFLATE
  gdal_translate "$detailed_projected" "$detailed_mbtiles" -of MBTiles \
    -co TILE_FORMAT=PNG -co MINZOOM="$DETAIL_ZOOM" -co MAXZOOM="$DETAIL_ZOOM" \
    -co NAME="$title" -co DESCRIPTION="$description"
  "$PMTILES_BIN" convert "$mbtiles" "$overview_pmtiles"
  "$PMTILES_BIN" convert "$detailed_mbtiles" "$detailed_pmtiles"
  "$PMTILES_BIN" merge "$overview_pmtiles" "$detailed_pmtiles" "$pmtiles"
  "$PMTILES_BIN" show --metadata "$pmtiles" | jq --argjson minzoom "$TARGET_ZOOM" --argjson maxzoom "$DETAIL_ZOOM" '.minzoom = $minzoom | .maxzoom = $maxzoom' > "$metadata_json"
  "$PMTILES_BIN" edit "$pmtiles" --metadata "$metadata_json"
  "$PMTILES_BIN" verify "$pmtiles"
}

shopt -s nullglob
inputs=("$INPUT_DIR"/*.tif "$INPUT_DIR"/*.tiff)
if [[ ${#inputs[@]} -eq 0 ]]; then
  printf 'Error: no TIFF files found in %s.\n' "$INPUT_DIR" >&2
  exit 1
fi

for input_path in "${inputs[@]}"; do
  filename=$(basename "$input_path")
  id="${filename%.*}"
  case "$filename" in
    built_s_2025_2000_cog.tif)
      build_raster "$id" "$filename" -234.94674682617 6637.8759765625 140 90 60 \
        'Built Surface Change (2000-2025)' \
        'Colorized raster PMTiles clipped to the configured boundary.'
      ;;
    built_s_nres_2025_2000_cog.tif)
      build_raster "$id" "$filename" 0 10000 196 96 255 \
        'Built Non-Residential Surface Change (2000-2025)' \
        'Colorized raster PMTiles clipped to the configured boundary.'
      ;;
    pop_2025_cog.tif|GHS_POP_E2025_GLOBE_R2023A_54009_100_V1_0_R7_C26.tif)
      build_raster "$id" "$filename" -336.37921142578 529.4892578125 165 15 21 \
        'Population Change (2000-2025)' \
        'Colorized raster PMTiles clipped to the configured boundary.' diverging
      ;;
    nightlights_*2025*.tif)
      build_raster "$id" "$filename" 0.47940674424171 65.227653503418 255 190 55 \
        'Nightlights (2025)' \
        'Colorized raster PMTiles clipped to the configured boundary.'
      ;;
    built_s_2025.tif)
      build_raster "$id" "$filename" 0 10000 166 102 62 \
        'Built Surface (2025)' \
        'Colorized raster PMTiles generated from the clipped TIFF.'
      ;;
    *)
      build_raster "$id" "$filename" 0 10000 39 111 108 \
        "Colorized raster: $filename" \
        'Colorized raster PMTiles generated from the clipped TIFF.'
      ;;
  esac
done