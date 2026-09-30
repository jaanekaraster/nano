#!/usr/bin/env bash

set -euo pipefail


# ============================================================
# NIGHTTIME LIGHTS -> MAHARASHTRA PIN-CODE STATISTICS
#
# Calculates exact / fractional-pixel zonal statistics from an
# analysis-ready VIIRS nighttime-lights raster.
#
# Default input:
#
#   data/processed/clipped/nightlights_2025_calibrated.tif
#
# PIN-code polygons:
#
#   data/districts/maharashtra_pincodes_fixed.geojson
#
# Output:
#
#   data/processed/nightlights_2025_by_pincode.csv
#
#
# Metrics:
#
#   mean_radiance
#       Area-weighted mean radiance over valid raster coverage.
#
#       Σ(R_i * A_i) / Σ(A_i)
#
#
#   sol
#       Sum-of-lights area integral:
#
#       Σ(R_i * A_i)
#
#       Units:
#       nW/(cm^2 sr) * km^2
#
#
#   valid_area_km2
#       Area of the PIN code covered by valid raster pixels.
#
#
#   pincode_area_km2
#       Geodesic area of the complete PIN-code polygon.
#
#
#   coverage_ratio
#       valid_area_km2 / pincode_area_km2
#
#
#   lit_area_km2
#       Valid area where radiance > LIT_THRESHOLD.
#
#
#   lit_area_ratio
#       lit_area_km2 / valid_area_km2
#
#
# IMPORTANT:
#
# Raster NoData is excluded.
#
# Pixels intersecting PIN-code boundaries are weighted by their
# fractional overlap with the polygon.
#
# Pixel area is calculated geodesically, so EPSG:4326 pixel
# area differences across Maharashtra are handled correctly.
#
# ============================================================


# ============================================================
# PROJECT PATHS
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DATA_DIR="$PROJECT_ROOT/nano/data"

PINCODE_FILE="$DATA_DIR/districts/maharashtra_pincodes_fixed.geojson"

RASTER_FILE="$DATA_DIR/processed/clipped/nightlights_2025_calibrated.tif"

OUTPUT_CSV="$DATA_DIR/processed/nightlights_2025_by_pincode.csv"


# ============================================================
# CONFIGURATION
# ============================================================

YEAR=2025

LIT_THRESHOLD=0

PINCODE_FIELD="pincode"

NODATA_VALUE=-9999


# ============================================================
# FUNCTIONS
# ============================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}


die() {
    echo "ERROR: $*" >&2
    exit 1
}


# ============================================================
# VALIDATION
# ============================================================

log "============================================================"
log "Nighttime lights -> Maharashtra PIN-code aggregation"
log "============================================================"

log "Year:          $YEAR"
log "Raster:        $RASTER_FILE"
log "PIN codes:     $PINCODE_FILE"
log "Output:        $OUTPUT_CSV"
log "Lit threshold: $LIT_THRESHOLD nW/(cm^2 sr)"


[[ -f "$RASTER_FILE" ]] ||
    die "Raster not found: $RASTER_FILE"


[[ -f "$PINCODE_FILE" ]] ||
    die "PIN-code file not found: $PINCODE_FILE"


command -v python3 >/dev/null 2>&1 ||
    die "python3 is required."


mkdir -p "$(dirname "$OUTPUT_CSV")"


# ============================================================
# CHECK PYTHON PACKAGES
# ============================================================

python3 - <<'PY'
import importlib.util
import sys

required = [
    "rasterio",
    "geopandas",
    "numpy",
    "pandas",
    "pyproj",
]

missing = [
    package
    for package in required
    if importlib.util.find_spec(package) is None
]

if missing:
    print(
        "ERROR: Missing Python packages: "
        + ", ".join(missing),
        file=sys.stderr,
    )
    print(
        "\nInstall them with:\n\n"
        "  pip install rasterio geopandas numpy pandas pyproj\n",
        file=sys.stderr,
    )
    sys.exit(1)
PY


# ============================================================
# RUN AGGREGATION
# ============================================================

export PINCODE_FILE
export RASTER_FILE
export OUTPUT_CSV
export YEAR
export LIT_THRESHOLD
export PINCODE_FIELD
export NODATA_VALUE


python3 <<'PY'

import os
import sys
import math

import numpy as np
import pandas as pd
import geopandas as gpd
import rasterio

from rasterio.mask import mask
from rasterio.features import geometry_mask
from rasterio.windows import from_bounds
from rasterio.windows import transform as window_transform

from shapely.geometry import box
from pyproj import Geod


# ============================================================
# CONFIG
# ============================================================

PINCODE_FILE = os.environ["PINCODE_FILE"]
RASTER_FILE = os.environ["RASTER_FILE"]
OUTPUT_CSV = os.environ["OUTPUT_CSV"]

YEAR = int(os.environ["YEAR"])

LIT_THRESHOLD = float(os.environ["LIT_THRESHOLD"])

PINCODE_FIELD = os.environ["PINCODE_FIELD"]

OUTPUT_NODATA = float(os.environ["NODATA_VALUE"])


# ============================================================
# HELPERS
# ============================================================

GEOD = Geod(ellps="WGS84")


def geodesic_area_km2(geometry):
    """
    Calculate geodesic polygon area in square kilometres.
    """

    if geometry is None or geometry.is_empty:
        return 0.0

    area_m2, _ = GEOD.geometry_area_perimeter(geometry)

    return abs(area_m2) / 1_000_000.0


def pixel_polygon(transform, row, col):
    """
    Return polygon representing one raster pixel.
    """

    x_left, y_top = transform * (col, row)

    x_right, y_bottom = transform * (col + 1, row + 1)

    return box(
        min(x_left, x_right),
        min(y_bottom, y_top),
        max(x_left, x_right),
        max(y_bottom, y_top),
    )


def safe_ratio(numerator, denominator):

    if denominator is None or denominator <= 0:
        return np.nan

    return numerator / denominator


# ============================================================
# LOAD PIN CODES
# ============================================================

print("Loading PIN-code polygons...")

gdf = gpd.read_file(PINCODE_FILE)


if PINCODE_FIELD not in gdf.columns:

    raise RuntimeError(
        f"PIN-code field '{PINCODE_FIELD}' not found. "
        f"Available fields: {list(gdf.columns)}"
    )


if gdf.crs is None:

    raise RuntimeError(
        "PIN-code GeoJSON has no CRS."
    )


# Keep PIN codes as strings.

gdf[PINCODE_FIELD] = (
    gdf[PINCODE_FIELD]
    .astype(str)
    .str.strip()
)


# ============================================================
# OPEN RASTER
# ============================================================

with rasterio.open(RASTER_FILE) as src:

    print()
    print("Raster information:")
    print(f"  CRS:       {src.crs}")
    print(f"  size:      {src.width} x {src.height}")
    print(f"  datatype:  {src.dtypes[0]}")
    print(f"  NoData:    {src.nodata}")
    print(f"  transform: {src.transform}")
    print()


    if src.crs is None:

        raise RuntimeError(
            "Nightlights raster has no CRS."
        )


    # --------------------------------------------------------
    # Transform PIN codes to raster CRS
    # --------------------------------------------------------

    if gdf.crs != src.crs:

        print(
            f"Reprojecting PIN codes from {gdf.crs} "
            f"to {src.crs}..."
        )

        gdf = gdf.to_crs(src.crs)


    # --------------------------------------------------------
    # This script calculates pixel areas geodesically.
    #
    # That requires geographic coordinates.
    # --------------------------------------------------------

    if not src.crs.is_geographic:

        raise RuntimeError(
            "This version expects a geographic raster "
            "(for example EPSG:4326)."
        )


    # ========================================================
    # PROCESS PIN CODES
    # ========================================================

    rows = []

    total = len(gdf)


    for index, feature in gdf.iterrows():

        pincode = feature[PINCODE_FIELD]

        district = feature.get("district", "")

        geometry = feature.geometry


        print(
            f"[{index + 1}/{total}] "
            f"PIN {pincode}",
            flush=True,
        )


        # ----------------------------------------------------
        # Handle empty geometry
        # ----------------------------------------------------

        if geometry is None or geometry.is_empty:

            rows.append({
                "pincode": pincode,
                "district": district,
                "year": YEAR,
                "sensor": "VIIRS",
                "mean_radiance": np.nan,
                "sol": np.nan,
                "pincode_area_km2": 0.0,
                "valid_area_km2": 0.0,
                "coverage_ratio": 0.0,
                "lit_area_km2": 0.0,
                "lit_area_ratio": np.nan,
                "valid_pixel_equiv": 0.0,
            })

            continue


        # ----------------------------------------------------
        # Full PIN-code area
        # ----------------------------------------------------

        pincode_area_km2 = geodesic_area_km2(geometry)


        # ----------------------------------------------------
        # Determine raster window intersecting polygon bounds
        # ----------------------------------------------------

        minx, miny, maxx, maxy = geometry.bounds


        window = from_bounds(
            minx,
            miny,
            maxx,
            maxy,
            transform=src.transform,
        )


        # Expand to whole pixels.

        window = window.round_offsets().round_lengths()


        # Clamp window to raster.

        full_window = rasterio.windows.Window(
            col_off=0,
            row_off=0,
            width=src.width,
            height=src.height,
        )


        try:

            window = window.intersection(full_window)

        except rasterio.errors.WindowError:

            rows.append({
                "pincode": pincode,
                "district": district,
                "year": YEAR,
                "sensor": "VIIRS",
                "mean_radiance": np.nan,
                "sol": np.nan,
                "pincode_area_km2": pincode_area_km2,
                "valid_area_km2": 0.0,
                "coverage_ratio": 0.0,
                "lit_area_km2": 0.0,
                "lit_area_ratio": np.nan,
                "valid_pixel_equiv": 0.0,
            })

            continue


        data = src.read(
            1,
            window=window,
            masked=False,
        )


        transform = window_transform(
            window,
            src.transform,
        )


        # ====================================================
        # EXACT FRACTIONAL PIXEL CALCULATION
        #
        # For every candidate raster pixel:
        #
        #   1. construct its geographic footprint
        #   2. intersect with the PIN polygon
        #   3. calculate geodesic intersection area
        #   4. use that exact area as the weight
        #
        # This avoids assigning entire edge pixels to a PIN.
        # ====================================================

        radiance_area_sum = 0.0

        valid_area_km2 = 0.0

        lit_area_km2 = 0.0

        valid_pixel_equiv = 0.0


        nrows, ncols = data.shape


        for row in range(nrows):

            for col in range(ncols):

                value = float(data[row, col])


                # --------------------------------------------
                # Exclude invalid / NoData raster values
                # --------------------------------------------

                if not math.isfinite(value):

                    continue


                if src.nodata is not None:

                    if np.isclose(value, src.nodata):

                        continue


                if np.isclose(value, OUTPUT_NODATA):

                    continue


                if value < 0:

                    continue


                # --------------------------------------------
                # Construct pixel polygon
                # --------------------------------------------

                px = pixel_polygon(
                    transform,
                    row,
                    col,
                )


                # Fast rejection.

                if not geometry.intersects(px):

                    continue


                # --------------------------------------------
                # Exact intersection
                # --------------------------------------------

                intersection = geometry.intersection(px)


                if intersection.is_empty:

                    continue


                intersection_area_km2 = (
                    geodesic_area_km2(intersection)
                )


                if intersection_area_km2 <= 0:

                    continue


                pixel_area_km2 = geodesic_area_km2(px)


                if pixel_area_km2 <= 0:

                    continue


                fraction = (
                    intersection_area_km2
                    /
                    pixel_area_km2
                )


                # --------------------------------------------
                # Accumulate valid area
                # --------------------------------------------

                valid_area_km2 += intersection_area_km2

                valid_pixel_equiv += fraction


                # --------------------------------------------
                # SOL
                #
                # radiance * intersected area
                # --------------------------------------------

                radiance_area_sum += (
                    value
                    *
                    intersection_area_km2
                )


                # --------------------------------------------
                # Lit area
                # --------------------------------------------

                if value > LIT_THRESHOLD:

                    lit_area_km2 += (
                        intersection_area_km2
                    )


        # ====================================================
        # DERIVED METRICS
        # ====================================================

        if valid_area_km2 > 0:

            mean_radiance = (
                radiance_area_sum
                /
                valid_area_km2
            )

            sol = radiance_area_sum

        else:

            mean_radiance = np.nan

            sol = np.nan


        coverage_ratio = safe_ratio(
            valid_area_km2,
            pincode_area_km2,
        )


        lit_area_ratio = safe_ratio(
            lit_area_km2,
            valid_area_km2,
        )


        rows.append({

            "pincode": pincode,

            "district": district,

            "year": YEAR,

            "sensor": "VIIRS",

            "mean_radiance": mean_radiance,

            "sol": sol,

            "pincode_area_km2": pincode_area_km2,

            "valid_area_km2": valid_area_km2,

            "coverage_ratio": coverage_ratio,

            "lit_area_km2": lit_area_km2,

            "lit_area_ratio": lit_area_ratio,

            "valid_pixel_equiv": valid_pixel_equiv,

        })


# ============================================================
# CREATE DATAFRAME
# ============================================================

result = pd.DataFrame(rows)


# ------------------------------------------------------------
# Sort PIN codes
# ------------------------------------------------------------

result = result.sort_values(
    ["pincode"],
    kind="stable",
)


# ------------------------------------------------------------
# Round output values
#
# Keep enough precision for downstream analysis.
# ------------------------------------------------------------

rounding = {

    "mean_radiance": 6,

    "sol": 6,

    "pincode_area_km2": 6,

    "valid_area_km2": 6,

    "coverage_ratio": 6,

    "lit_area_km2": 6,

    "lit_area_ratio": 6,

    "valid_pixel_equiv": 6,

}


result = result.round(rounding)


# ============================================================
# WRITE CSV
# ============================================================

result.to_csv(
    OUTPUT_CSV,
    index=False,
)


# ============================================================
# SUMMARY
# ============================================================

print()
print("============================================================")
print("Aggregation complete")
print("============================================================")

print(f"PIN codes: {len(result)}")

print(
    "PIN codes with valid radiance: "
    f"{result['mean_radiance'].notna().sum()}"
)

print(
    "Mean coverage ratio: "
    f"{result['coverage_ratio'].mean():.4f}"
)

print(
    "Median coverage ratio: "
    f"{result['coverage_ratio'].median():.4f}"
)

print()
print(f"Output: {OUTPUT_CSV}")
print()

print("Columns:")
print()

for column in result.columns:
    print(f"  {column}")

print()

PY


# ============================================================
# FINISHED
# ============================================================

log "============================================================"
log "PIN-code aggregation complete"
log "============================================================"

log "Output:"
log "$OUTPUT_CSV"

log ""

log "Preview:"

head -n 6 "$OUTPUT_CSV"