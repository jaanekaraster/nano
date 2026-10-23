#!/usr/bin/env bash

set -euo pipefail

============================================================
NIGHTTIME LIGHTS -> MAHARASHTRA PIN-CODE STATISTICS
Outputs:
1. CSV containing PIN-code zonal statistics
2. GeoJSON containing PIN-code geometries + all statistics
Method:
- Area-weighted radiance statistics
- Fractional pixel/polygon intersection weights
- Geodesic area calculations on WGS84
- Vectorized Shapely 2 intersection operations
Requirements:
Python 3
rasterio
geopandas
numpy
pandas
pyproj
shapely >= 2.0
============================================================
============================================================
PROJECT PATHS
============================================================

SCRIPT_DIR="(cd"(dirname "${BASH_SOURCE[0]}")" && pwd)" PROJECT_ROOT="(cd"SCRIPT_DIR/../.." && pwd)"

DATA_DIR="$PROJECT_ROOT/nano/data"

PINCODE_FILE="$DATA_DIR/districts/maharashtra_pincodes_fixed.geojson"

RASTER_FILE="$DATA_DIR/processed/clipped/nightlights_2025_calibrated.tif"

OUTPUT_CSV="$DATA_DIR/processed/nightlights_2025_by_pincode.csv"

OUTPUT_GEOJSON="$DATA_DIR/processed/nightlights_2025_by_pincode.geojson"

============================================================
CONFIGURATION
============================================================

YEAR=2025

LIT_THRESHOLD=0

PINCODE_FIELD="pincode"

NODATA_VALUE=-9999

Maximum number of candidate pixels processed in one batch.
Increase if RAM permits; decrease for machines with limited RAM.

PIXEL_BATCH_SIZE=20000

============================================================
FUNCTIONS
============================================================

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" }

die() { echo "ERROR: $*" >&2 exit 1 }

============================================================
VALIDATION
============================================================

log "============================================================" log "Nighttime lights -> Maharashtra PIN-code aggregation" log "============================================================"

log "Year: $YEAR" log "Raster: $RASTER_FILE" log "PIN codes: $PINCODE_FILE" log "CSV output: $OUTPUT_CSV" log "GeoJSON output: $OUTPUT_GEOJSON" log "Lit threshold: $LIT_THRESHOLD nW/(cm^2 sr)"

[[ -f "$RASTER_FILE" ]] || die "Raster not found: $RASTER_FILE"

[[ -f "$PINCODE_FILE" ]] || die "PIN-code file not found: $PINCODE_FILE"

command -v python3 >/dev/null 2>&1 || die "python3 is required."

mkdir -p "(dirname"OUTPUT_CSV")" mkdir -p "(dirname"OUTPUT_GEOJSON")"

============================================================
CHECK PYTHON PACKAGES
============================================================

python3 - <<'PY' import importlib.util import sys

required = [ "rasterio", "geopandas", "numpy", "pandas", "pyproj", "shapely", ]

missing = [ package for package in required if importlib.util.find_spec(package) is None ]

if missing: print( "ERROR: Missing Python packages: " + ", ".join(missing), file=sys.stderr, ) print( "\nInstall with:\n" " python3 -m pip install rasterio geopandas numpy pandas pyproj 'shapely>=2.0'\n", file=sys.stderr, ) sys.exit(1)

import shapely

if int(shapely.version.split(".")[0]) < 2: print( "ERROR: Shapely 2.0 or later is required.", file=sys.stderr, ) sys.exit(1) PY

============================================================
RUN AGGREGATION
============================================================

export PINCODE_FILE export RASTER_FILE export OUTPUT_CSV export OUTPUT_GEOJSON export YEAR export LIT_THRESHOLD export PINCODE_FIELD export NODATA_VALUE export PIXEL_BATCH_SIZE

python3 <<'PY' import os import sys import math import warnings

import numpy as np import pandas as pd import geopandas as gpd import rasterio

from rasterio.windows import from_bounds, transform as window_transform from rasterio.windows import Window from rasterio.errors import WindowError

from shapely.geometry import box from shapely import intersection, area, is_empty, is_valid, make_valid from pyproj import Geod

============================================================
CONFIG
============================================================

PINCODE_FILE = os.environ["PINCODE_FILE"] RASTER_FILE = os.environ["RASTER_FILE"] OUTPUT_CSV = os.environ["OUTPUT_CSV"] OUTPUT_GEOJSON = os.environ["OUTPUT_GEOJSON"]

YEAR = int(os.environ["YEAR"]) LIT_THRESHOLD = float(os.environ["LIT_THRESHOLD"]) PINCODE_FIELD = os.environ["PINCODE_FIELD"] OUTPUT_NODATA = float(os.environ["NODATA_VALUE"]) BATCH_SIZE = int(os.environ["PIXEL_BATCH_SIZE"])

GEOD = Geod(ellps="WGS84")

============================================================
GEODESIC AREA HELPERS
============================================================

def geodesic_area_km2(geometry): """Return absolute WGS84 geodesic area in square kilometres.""" if geometry is None or geometry.is_empty: return 0.0

area_m2, _ = GEOD.geometry_area_perimeter(geometry)
return abs(area_m2) / 1_000_000.0


def geodesic_areas_km2(geometries): """ Calculate geodesic areas for a sequence of geometries.

PyProj supports vectorized coordinate arrays for simple rings,
but polygon holes and multipart geometries need careful handling.
Use the reliable geometry API here; intersection calculations
themselves are batched.
"""
return np.fromiter(
    (geodesic_area_km2(g) for g in geometries),
    dtype=np.float64,
    count=len(geometries),
)


def safe_ratio(numerator, denominator): if denominator is None or not np.isfinite(denominator) or denominator <= 0: return np.nan return numerator / denominator

def empty_result(pincode, district, pincode_area): return { "pincode": pincode, "district": district, "year": YEAR, "sensor": "VIIRS", "mean_radiance": np.nan, "sol": np.nan, "pincode_area_km2": pincode_area, "valid_area_km2": 0.0, "coverage_ratio": 0.0 if pincode_area > 0 else np.nan, "lit_area_km2": 0.0, "lit_area_ratio": np.nan, "valid_pixel_equiv": 0.0, }

============================================================
LOAD PIN-CODE POLYGONS
============================================================

print("Loading PIN-code polygons...", flush=True)

gdf = gpd.read_file(PINCODE_FILE)

if gdf.empty: raise RuntimeError("PIN-code file contains no features.")

if PINCODE_FIELD not in gdf.columns: raise RuntimeError( f"PIN-code field '{PINCODE_FIELD}' not found. " f"Available fields: {list(gdf.columns)}" )

if gdf.crs is None: raise RuntimeError("PIN-code GeoJSON has no CRS.")

Preserve PIN codes as strings, including leading zeroes.

gdf[PINCODE_FIELD] = gdf[PINCODE_FIELD].astype("string").str.strip()

if "district" not in gdf.columns: gdf["district"] = ""

Repair invalid polygon geometries where possible.

invalid = ~gdf.geometry.is_valid & gdf.geometry.notna()

if invalid.any(): print( f"Repairing {int(invalid.sum())} invalid PIN-code geometries...", flush=True, ) gdf.loc[invalid, "geometry"] = gdf.loc[invalid, "geometry"].map( lambda geom: make_valid(geom) if geom is not None else None )

Drop null/empty geometries from spatial processing, but retain the
records and their attributes in the output.

gdf = gdf.reset_index(drop=True)

============================================================
OPEN RASTER
============================================================

rows = []

with rasterio.open(RASTER_FILE) as src:

print("\nRaster information:", flush=True)
print(f"  CRS:      {src.crs}", flush=True)
print(f"  Size:     {src.width} x {src.height}", flush=True)
print(f"  Type:     {src.dtypes[0]}", flush=True)
print(f"  NoData:   {src.nodata}", flush=True)
print(f"  Transform:{src.transform}", flush=True)

if src.crs is None:
    raise RuntimeError("Nightlights raster has no CRS.")

if not src.crs.is_geographic:
    raise RuntimeError(
        "This script calculates geodesic pixel areas and expects "
        "a geographic raster, for example EPSG:4326."
    )

# Reproject polygons into the raster CRS for pixel intersection.
if gdf.crs != src.crs:
    print(
        f"\nReprojecting PIN codes from {gdf.crs} to {src.crs}...",
        flush=True,
    )
    gdf = gdf.to_crs(src.crs)

# GeoJSON output must use WGS84 longitude/latitude.
# Retain a WGS84 version of the geometries for final export.
output_gdf = gdf.to_crs("EPSG:4326").copy()

total = len(gdf)

for feature_index, feature in gdf.iterrows():

    pincode = feature[PINCODE_FIELD]
    district = feature.get("district", "")
    geometry = feature.geometry

    if pd.isna(pincode):
        pincode = ""

    pincode = str(pincode).strip()
    district = "" if pd.isna(district) else str(district)

    print(
        f"[{feature_index + 1}/{total}] PIN {pincode}",
        flush=True,
    )

    # Handle missing and empty geometries.
    if geometry is None or geometry.is_empty:
        rows.append(empty_result(pincode, district, 0.0))
        continue

    # Full PIN-code polygon area, independent of raster coverage.
    pincode_area_km2 = geodesic_area_km2(geometry)

    if pincode_area_km2 <= 0:
        rows.append(empty_result(pincode, district, pincode_area_km2))
        continue

    minx, miny, maxx, maxy = geometry.bounds

    # Determine candidate raster window from polygon bounds.
    try:
        window = from_bounds(
            minx,
            miny,
            maxx,
            maxy,
            transform=src.transform,
        ).round_offsets().round_lengths()

        full_window = Window(
            col_off=0,
            row_off=0,