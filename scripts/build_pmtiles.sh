#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUILD_DIR="$ROOT/build/pmtiles"
OUTPUT_DIR="$ROOT/data/pmtiles"
PMTILES_BIN="${PMTILES_BIN:-pmtiles}"
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
  local ramp="$BUILD_DIR/${id}.txt"
  local colorized="$BUILD_DIR/${id}_color.tif"
  local projected="$BUILD_DIR/${id}_3857.tif"
  local mbtiles="$BUILD_DIR/${id}.mbtiles"
  local pmtiles="$OUTPUT_DIR/${id}.pmtiles"

  printf '%s\n' \
    'nv 0 0 0 0' \
    "$min_value $red $green $blue 0" \
    "$max_value $red $green $blue 255" > "$ramp"

  gdaldem color-relief "$ROOT/data/$input" "$ramp" "$colorized" \
    -alpha -of GTiff -co TILED=YES -co COMPRESS=DEFLATE
  gdalwarp "$colorized" "$projected" -t_srs EPSG:3857 -r bilinear \
    -dstalpha -of GTiff -co TILED=YES -co COMPRESS=DEFLATE
  gdal_translate "$projected" "$mbtiles" -of MBTiles \
    -co TILE_FORMAT=PNG -co MINZOOM=8 -co MAXZOOM=14 \
    -co NAME="$title" -co DESCRIPTION="$description"
  "$PMTILES_BIN" convert "$mbtiles" "$pmtiles"
  "$PMTILES_BIN" verify "$pmtiles"
}

build_raster \
  built_s \
  aurangabad_built_s_2025_2000_cog_clipped.tif \
  -234.94674682617 6637.8759765625 0 191 255 \
  'Built Surface Change (2000-2025)' \
  'Colorized raster PMTiles clipped to Aurangabad pincode boundaries.'

build_raster \
  built_s_nres \
  aurangabad_built_s_nres_2025_2000_cog_clipped.tif \
  0 10000 196 96 255 \
  'Built Non-Residential Surface Change (2000-2025)' \
  'Colorized raster PMTiles clipped to Aurangabad pincode boundaries.'

build_raster \
  population \
  aurangabad_pop_2025_2000_clipped.tif \
  -336.37921142578 529.4892578125 255 34 55 \
  'Population Change (2000-2025)' \
  'Colorized raster PMTiles clipped to Aurangabad pincode boundaries.'

build_raster \
  nightlights \
  nightlights_aurangabad_2025_clipped.tif \
  0.47940674424171 65.227653503418 255 190 55 \
  'Nightlights (2025)' \
  'Colorized raster PMTiles clipped to Aurangabad pincode boundaries.'
