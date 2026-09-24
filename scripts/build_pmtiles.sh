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

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

TARGET_ZOOM="${TARGET_ZOOM:-6}"
DETAIL_ZOOM="${DETAIL_ZOOM:-11}"

# Web Mercator ground resolution at the equator, metres/pixel.
TARGET_RESOLUTION=$(awk -v zoom="$TARGET_ZOOM" \
  'BEGIN { printf "%.12f", 156543.03392804097 / (2 ^ zoom) }')

DETAIL_RESOLUTION=$(awk -v zoom="$DETAIL_ZOOM" \
  'BEGIN { printf "%.12f", 156543.03392804097 / (2 ^ zoom) }')

# GDAL resource settings.
#
# GDAL_CACHEMAX is in MB. Override with:
#
#   GDAL_CACHEMAX=1024 ./scripts/build_pmtiles.sh
#
# WARP_THREADS can be set to a number or ALL_CPUS.
GDAL_CACHEMAX="${GDAL_CACHEMAX:-512}"
WARP_THREADS="${WARP_THREADS:-ALL_CPUS}"

export GDAL_CACHEMAX

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Validate dependencies
# ---------------------------------------------------------------------------

for cmd in gdalinfo gdalwarp gdal_translate gdaldem awk jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found: $cmd" >&2
    exit 1
  fi
done

if ! command -v "$PMTILES_BIN" >/dev/null 2>&1; then
  echo "Error: pmtiles executable not found." >&2
  exit 1
fi

echo "GDAL cache:       ${GDAL_CACHEMAX} MB"
echo "Warp threads:     ${WARP_THREADS}"
echo "Overview zoom:    ${TARGET_ZOOM}"
echo "Overview res:     ${TARGET_RESOLUTION} m/pixel"
echo "Detail zoom:      ${DETAIL_ZOOM}"
echo "Detail res:       ${DETAIL_RESOLUTION} m/pixel"
echo

# ---------------------------------------------------------------------------
# Build one raster
# ---------------------------------------------------------------------------

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

  local projected="$BUILD_DIR/${id}_3857_overview.tif"
  local detailed_projected="$BUILD_DIR/${id}_3857_detail.tif"

  local colorized="$BUILD_DIR/${id}_overview_color.tif"
  local detailed_colorized="$BUILD_DIR/${id}_detail_color.tif"

  local mbtiles="$BUILD_DIR/${id}_overview.mbtiles"
  local detailed_mbtiles="$BUILD_DIR/${id}_detail.mbtiles"

  local overview_pmtiles="$BUILD_DIR/${id}_overview.pmtiles"
  local detailed_pmtiles="$BUILD_DIR/${id}_detail.pmtiles"

  local metadata_json="$BUILD_DIR/${id}_metadata.json"

  local pmtiles="$OUTPUT_DIR/${id}.pmtiles"

  echo
  echo "============================================================"
  echo "Building: $id"
  echo "Input:    $INPUT_DIR/$input"
  echo "============================================================"

  # -------------------------------------------------------------------------
  # Clean previous outputs
  # -------------------------------------------------------------------------

  rm -f \
    "$ramp" \
    "$projected" \
    "$detailed_projected" \
    "$colorized" \
    "$detailed_colorized" \
    "$mbtiles" \
    "$detailed_mbtiles" \
    "$overview_pmtiles" \
    "$detailed_pmtiles" \
    "$metadata_json" \
    "$pmtiles"

  # -------------------------------------------------------------------------
  # Create color ramp
  # -------------------------------------------------------------------------

  if [[ "$mode" == "diverging" ]]; then

    local mid_value
    mid_value=$(awk \
      -v a="$min_value" \
      -v b="$max_value" \
      'BEGIN { printf "%.6f", (a + b) / 2 }')

    local neg_mid
    neg_mid=$(awk \
      -v a="$min_value" \
      -v b="$mid_value" \
      'BEGIN { printf "%.6f", (a + b) / 2 }')

    local pos_mid
    pos_mid=$(awk \
      -v a="$mid_value" \
      -v b="$max_value" \
      'BEGIN { printf "%.6f", (a + b) / 2 }')

    printf '%s\n' \
      'nv 255 255 255 0' \
      "$min_value 140 81 10 235" \
      "$neg_mid 191 129 45 200" \
      "0 245 245 245 0" \
      "$pos_mid 90 180 172 200" \
      "$max_value 1 102 94 235" \
      > "$ramp"

  else

    # Sequential ramp.
    #
    # Transparency at the minimum value makes zero/empty areas disappear
    # while retaining the requested color toward the maximum.
    printf '%s\n' \
      'nv 255 255 255 0' \
      "$min_value $red $green $blue 0" \
      "$max_value $red $green $blue 235" \
      > "$ramp"

  fi

  echo "Color ramp: $ramp"

  # -------------------------------------------------------------------------
  # Overview: warp source directly to EPSG:3857 at target zoom resolution.
  #
  # IMPORTANT:
  # We deliberately warp BEFORE colorizing.
  #
  # The input has:
  #   Band 1 = Float32 data
  #   Band 2 = alpha
  #
  # We use only band 1 and let gdalwarp generate a fresh alpha band.
  # -------------------------------------------------------------------------

  echo
  echo "Warping overview to EPSG:3857..."

  gdalwarp \
    "$INPUT_DIR/$input" \
    "$projected" \
    -b 1 \
    -t_srs EPSG:3857 \
    -r bilinear \
    -tr "$TARGET_RESOLUTION" "$TARGET_RESOLUTION" \
    -dstalpha \
    -multi \
    -wo "NUM_THREADS=$WARP_THREADS" \
    -wm 512 \
    -of GTiff \
    -ot Float32 \
    -co TILED=YES \
    -co COMPRESS=DEFLATE \
    -co BIGTIFF=IF_SAFER

  # -------------------------------------------------------------------------
  # Colorize overview.
  #
  # This raster is now dramatically smaller than the original 100 m raster.
  # -------------------------------------------------------------------------

  echo "Colorizing overview..."

  gdaldem color-relief \
    "$projected" \
    "$ramp" \
    "$colorized" \
    -alpha \
    -of GTiff \
    -co TILED=YES \
    -co COMPRESS=DEFLATE \
    -co BIGTIFF=IF_SAFER

  # -------------------------------------------------------------------------
  # Convert overview to MBTiles
  # -------------------------------------------------------------------------

  echo "Creating overview MBTiles..."

  gdal_translate \
    "$colorized" \
    "$mbtiles" \
    -of MBTiles \
    -co TILE_FORMAT=PNG \
    -co MINZOOM="$TARGET_ZOOM" \
    -co MAXZOOM="$TARGET_ZOOM" \
    -co NAME="$title" \
    -co DESCRIPTION="$description"

  # -------------------------------------------------------------------------
  # Detail: warp source directly to EPSG:3857 at detail zoom resolution.
  # -------------------------------------------------------------------------

  echo
  echo "Warping detail to EPSG:3857..."

  gdalwarp \
    "$INPUT_DIR/$input" \
    "$detailed_projected" \
    -b 1 \
    -t_srs EPSG:3857 \
    -r bilinear \
    -tr "$DETAIL_RESOLUTION" "$DETAIL_RESOLUTION" \
    -dstalpha \
    -multi \
    -wo "NUM_THREADS=$WARP_THREADS" \
    -wm 512 \
    -of GTiff \
    -ot Float32 \
    -co TILED=YES \
    -co COMPRESS=DEFLATE \
    -co BIGTIFF=IF_SAFER

  # -------------------------------------------------------------------------
  # Colorize detail
  # -------------------------------------------------------------------------

  echo "Colorizing detail..."

  gdaldem color-relief \
    "$detailed_projected" \
    "$ramp" \
    "$detailed_colorized" \
    -alpha \
    -of GTiff \
    -co TILED=YES \
    -co COMPRESS=DEFLATE \
    -co BIGTIFF=IF_SAFER

  # -------------------------------------------------------------------------
  # Convert detail to MBTiles
  # -------------------------------------------------------------------------

  echo "Creating detail MBTiles..."

  gdal_translate \
    "$detailed_colorized" \
    "$detailed_mbtiles" \
    -of MBTiles \
    -co TILE_FORMAT=PNG \
    -co MINZOOM="$DETAIL_ZOOM" \
    -co MAXZOOM="$DETAIL_ZOOM" \
    -co NAME="$title" \
    -co DESCRIPTION="$description"

  # -------------------------------------------------------------------------
  # Convert both MBTiles files to PMTiles
  # -------------------------------------------------------------------------

  echo "Converting overview to PMTiles..."

  "$PMTILES_BIN" convert \
    "$mbtiles" \
    "$overview_pmtiles"

  echo "Converting detail to PMTiles..."

  "$PMTILES_BIN" convert \
    "$detailed_mbtiles" \
    "$detailed_pmtiles"

  # -------------------------------------------------------------------------
  # Merge overview + detail
  # -------------------------------------------------------------------------

  echo "Merging PMTiles..."

  "$PMTILES_BIN" merge \
    "$overview_pmtiles" \
    "$detailed_pmtiles" \
    "$pmtiles"

  # -------------------------------------------------------------------------
  # Set metadata
  # -------------------------------------------------------------------------

  echo "Updating PMTiles metadata..."

  "$PMTILES_BIN" show --metadata "$pmtiles" |
    jq \
      --argjson minzoom "$TARGET_ZOOM" \
      --argjson maxzoom "$DETAIL_ZOOM" \
      --arg name "$title" \
      --arg description "$description" \
      '.minzoom = $minzoom
       | .maxzoom = $maxzoom
       | .name = $name
       | .description = $description' \
    > "$metadata_json"

  "$PMTILES_BIN" edit \
    "$pmtiles" \
    --metadata "$metadata_json"

  # -------------------------------------------------------------------------
  # Verify
  # -------------------------------------------------------------------------

  echo "Verifying PMTiles..."

  "$PMTILES_BIN" verify "$pmtiles"

  echo "Finished: $pmtiles"

  # -------------------------------------------------------------------------
  # Remove large intermediate files.
  #
  # Keep the ramp and final PMTiles; everything else can be regenerated.
  # -------------------------------------------------------------------------

  rm -f \
    "$projected" \
    "$detailed_projected" \
    "$colorized" \
    "$detailed_colorized" \
    "$mbtiles" \
    "$detailed_mbtiles" \
    "$overview_pmtiles" \
    "$detailed_pmtiles" \
    "$metadata_json"

  echo "Cleaned intermediate files."
}

# ---------------------------------------------------------------------------
# Find input TIFFs
# ---------------------------------------------------------------------------

shopt -s nullglob

inputs=(
  "$INPUT_DIR"/*.tif
  "$INPUT_DIR"/*.tiff
)

if [[ ${#inputs[@]} -eq 0 ]]; then
  printf 'Error: no TIFF files found in %s.\n' "$INPUT_DIR" >&2
  exit 1
fi

echo "Found ${#inputs[@]} input raster(s)."

# ---------------------------------------------------------------------------
# Process inputs
# ---------------------------------------------------------------------------

for input_path in "${inputs[@]}"; do

  filename=$(basename "$input_path")
  id="${filename%.*}"

  case "$filename" in

    ghs_built_s_change_2020_2025.tif)
      build_raster \
        "$id" \
        "$filename" \
        -234.94674682617 \
        6637.8759765625 \
        140 90 60 \
        'Built Surface Change (2020-2025)' \
        'Colorized raster PMTiles clipped to the configured boundary.' \
        "diverging"
      ;;

    ghs_built_s_nres_change_2020_2025.tif)
      build_raster \
        "$id" \
        "$filename" \
        0 \
        10000 \
        196 96 255 \
        'Built Non-Residential Surface Change (2020-2025)' \
        'Colorized raster PMTiles clipped to the configured boundary.' \
        "diverging"
      ;;

    ghs_built_s_res_change_2020_2025.tif)
      build_raster \
        "$id" \
        "$filename" \
        0 \
        10000 \
        196 96 255 \
        'Built Residential Surface Change (2020-2025)' \
        'Colorized raster PMTiles clipped to the configured boundary.' \
        "diverging"
      ;;

    ghs_pop_change_2020_2025.tif)
      build_raster \
        "$id" \
        "$filename" \
        0 \
        10000 \
        196 96 255 \
        'Population Change (2020-2025)' \
        'Colorized raster PMTiles clipped to the configured boundary.' \
        "diverging"
      ;;

    nightlights_change_2020_2025.tif)
      build_raster \
        "$id" \
        "$filename" \
        0.47940674424171 \
        65.227653503418 \
        255 190 55 \
        'Nightlights Change (2020-2025)' \
        'Colorized raster PMTiles clipped to the configured boundary.' \
        "diverging"
      ;;

    ghs_pop_2025.tif)
      build_raster \
        "$id" \
        "$filename" \
        0 \
        529.4892578125 \
        118 42 131 \
        'Population (2025)' \
        'Colorized raster PMTiles clipped to the configured boundary.'
      ;;

    nightlights_*2020*.tif)
      build_raster \
        "$id" \
        "$filename" \
        0.47940674424171 \
        65.227653503418 \
        255 190 55 \
        'Nightlights (2025)' \
        'Colorized raster PMTiles clipped to the configured boundary.'
      ;;

    nightlights_*2025*.tif)
      build_raster \
        "$id" \
        "$filename" \
        0.47940674424171 \
        65.227653503418 \
        255 190 55 \
        'Nightlights (2025)' \
        'Colorized raster PMTiles clipped to the configured boundary.'
      ;;

    ghs_built_s_2020.tif)
      build_raster \
        "$id" \
        "$filename" \
        0 \
        10000 \
        166 102 62 \
        'Built Surface (2020)' \
        'Colorized raster PMTiles generated from the clipped TIFF.'
      ;;

    ghs_built_s_2025.tif)
      build_raster \
        "$id" \
        "$filename" \
        0 \
        10000 \
        166 102 62 \
        'Built Surface (2025)' \
        'Colorized raster PMTiles generated from the clipped TIFF.'
      ;;

    ghs_built_s_2020_residential.tif)
      build_raster \
        "$id" \
        "$filename" \
        0 \
        10000 \
        166 102 62 \
        'Built Surface Residential (2020)' \
        'Colorized raster PMTiles generated from the clipped TIFF.'
      ;;

    ghs_built_s_2025_residential.tif)
      build_raster \
        "$id" \
        "$filename" \
        0 \
        10000 \
        166 102 62 \
        'Built Surface Residential (2025)' \
        'Colorized raster PMTiles generated from the clipped TIFF.'
      ;;

    ghs_built_s_2020_nres.tif)
      build_raster \
        "$id" \
        "$filename" \
        0 \
        10000 \
        166 102 62 \
        'Built Surface Non-Residential (2020)' \
        'Colorized raster PMTiles generated from the clipped TIFF.'
      ;;

    ghs_built_s_2025_nres.tif)
      build_raster \
        "$id" \
        "$filename" \
        0 \
        10000 \
        166 102 62 \
        'Built Surface Non-Residential (2025)' \
        'Colorized raster PMTiles generated from the clipped TIFF.'
      ;;

    *)
      build_raster \
        "$id" \
        "$filename" \
        0 \
        10000 \
        39 111 108 \
        "Colorized raster: $filename" \
        'Colorized raster PMTiles generated from the clipped TIFF.'
      ;;

  esac

done

echo
echo "============================================================"
echo "All PMTiles builds completed successfully."
echo "Output directory:"
echo "  $OUTPUT_DIR"
echo "============================================================"