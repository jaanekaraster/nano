#!/usr/bin/env bash

set -euo pipefail


# ============================================================
# GHS-POP 2025 -> MAHARASHTRA PIN-CODE POPULATION
#
# FAST VERSION
#
# Uses exactextract for compiled fractional-pixel zonal
# statistics instead of looping over individual raster cells
# in Python.
#
#
# Input raster:
#
#   data/processed/clipped/ghs_pop_2025.tif
#
# PIN-code polygons:
#
#   data/districts/maharashtra_pincodes_fixed.geojson
#
# Output:
#
#   data/processed/ghs_pop_2025_by_pincode.csv
#
#
# ============================================================
# METRICS
# ============================================================
#
# population_2025
#
#   Fractional-pixel population sum:
#
#       SUM(population_pixel * polygon_fraction)
#
#   If 30% of a population cell falls inside a PIN code,
#   30% of that cell's population is allocated to the PIN.
#
#
# pincode_area_km2
#
#   Geodesic area of the complete PIN-code polygon.
#
#
# population_density_km2
#
#       population_2025 / pincode_area_km2
#
#
# valid_area_km2
#
#   Approximate area represented by valid source raster cells.
#
#
# coverage_ratio
#
#       valid_area_km2 / pincode_area_km2
#
#
# source_pixel_equiv
#
#   Fractional equivalent number of valid GHS-POP pixels
#   contributing to the PIN code.
#
#
# IMPORTANT
# ============================================================
#
# GHS-POP pixels represent population counts, NOT population
# density.
#
# Therefore the correct aggregation is a fractional-pixel SUM,
# not a mean.
#
# ============================================================


# ============================================================
# PROJECT PATHS
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Keep this consistent with the project structure in the
# existing script.
DATA_DIR="$PROJECT_ROOT/nano/data"

PINCODE_FILE="$DATA_DIR/districts/maharashtra_pincodes_fixed.geojson"

RASTER_FILE="$DATA_DIR/processed/clipped/ghs_pop_2025.tif"

OUTPUT_CSV="$DATA_DIR/processed/ghs_pop_2025_by_pincode.csv"


# ============================================================
# CONFIGURATION
# ============================================================

YEAR=2025

PINCODE_FIELD="pincode"


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
log "GHS-POP -> Maharashtra PIN-code aggregation"
log "============================================================"

log "Year:      $YEAR"
log "Raster:    $RASTER_FILE"
log "PIN codes: $PINCODE_FILE"
log "Output:    $OUTPUT_CSV"


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
    "shapely",
    "exactextract",
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
        "  pip install rasterio geopandas numpy pandas "
        "pyproj shapely exactextract\n",
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
export PINCODE_FIELD


python3 <<'PY'

import os
import math

import numpy as np
import pandas as pd
import geopandas as gpd
import rasterio

from exactextract import exact_extract

from pyproj import CRS, Geod


# ============================================================
# CONFIG
# ============================================================

PINCODE_FILE = os.environ["PINCODE_FILE"]

RASTER_FILE = os.environ["RASTER_FILE"]

OUTPUT_CSV = os.environ["OUTPUT_CSV"]

YEAR = int(os.environ["YEAR"])

PINCODE_FIELD = os.environ["PINCODE_FIELD"]


GEOD = Geod(ellps="WGS84")


# ============================================================
# HELPERS
# ============================================================

def geodesic_area_km2(geometry):
    """
    Calculate WGS84 geodesic polygon area in square kilometres.

    Input geometry must be EPSG:4326.
    """

    if geometry is None or geometry.is_empty:
        return 0.0

    area_m2, _ = GEOD.geometry_area_perimeter(
        geometry
    )

    return abs(area_m2) / 1_000_000.0


def safe_ratio(numerator, denominator):

    if denominator is None:
        return np.nan

    if not np.isfinite(denominator):
        return np.nan

    if denominator <= 0:
        return np.nan

    return numerator / denominator


# ============================================================
# LOAD PIN CODES
# ============================================================

print()
print("Loading PIN-code polygons...")

gdf = gpd.read_file(
    PINCODE_FILE
)


if PINCODE_FIELD not in gdf.columns:

    raise RuntimeError(
        f"Field '{PINCODE_FIELD}' not found. "
        f"Available fields: {list(gdf.columns)}"
    )


if gdf.crs is None:

    raise RuntimeError(
        "PIN-code GeoJSON has no CRS."
    )


# ------------------------------------------------------------
# Keep PIN codes as strings.
# ------------------------------------------------------------

gdf[PINCODE_FIELD] = (
    gdf[PINCODE_FIELD]
    .astype(str)
    .str.strip()
)


# ============================================================
# GUARANTEE ONE FEATURE PER PIN CODE
#
# If the source happens to contain multiple polygon features
# with the same PIN code, dissolve them before extraction.
#
# This guarantees the final CSV contains exactly one row per
# unique PIN code.
# ============================================================

original_feature_count = len(gdf)

unique_pincode_count = gdf[PINCODE_FIELD].nunique()


print(
    f"Input polygon features: {original_feature_count}"
)

print(
    f"Unique PIN codes:       {unique_pincode_count}"
)


if original_feature_count != unique_pincode_count:

    print()
    print(
        "Duplicate PIN-code features detected; "
        "dissolving by pincode..."
    )


    # Keep district as contextual metadata.

    gdf = (
        gdf[
            [
                PINCODE_FIELD,
                "district",
                "geometry",
            ]
        ]
        .dissolve(
            by=PINCODE_FIELD,
            aggfunc={
                "district": "first",
            },
        )
        .reset_index()
    )


    print(
        f"Dissolved features:     {len(gdf)}"
    )

else:

    gdf = gdf[
        [
            PINCODE_FIELD,
            "district",
            "geometry",
        ]
    ].copy()


# ============================================================
# FIX INVALID GEOMETRIES IF NECESSARY
# ============================================================

invalid_count = int(
    (~gdf.geometry.is_valid).sum()
)


if invalid_count > 0:

    print()
    print(
        f"Repairing {invalid_count} invalid geometries..."
    )

    gdf.geometry = gdf.geometry.make_valid()


# ============================================================
# CALCULATE PIN-CODE AREA
#
# Calculate from WGS84 using the ellipsoid rather than using
# degrees² or relying on the population raster projection.
# ============================================================

print()
print("Calculating PIN-code areas...")


gdf_wgs84 = gdf.to_crs(
    "EPSG:4326"
)


gdf["_pincode_area_km2"] = [
    geodesic_area_km2(geometry)
    for geometry in gdf_wgs84.geometry
]


# ============================================================
# INSPECT GHS-POP RASTER
# ============================================================

print()
print("Opening GHS-POP raster...")


with rasterio.open(RASTER_FILE) as src:

    if src.crs is None:

        raise RuntimeError(
            "GHS-POP raster has no CRS."
        )


    raster_crs = CRS.from_user_input(
        src.crs
    )


    print()
    print("Raster information:")
    print(f"  CRS:       {src.crs}")
    print(f"  size:      {src.width} x {src.height}")
    print(f"  datatype:  {src.dtypes[0]}")
    print(f"  NoData:    {src.nodata}")
    print(f"  transform: {src.transform}")
    print()


    # ========================================================
    # GHS-POP SHOULD BE PROJECTED FOR THE AREA QA CALCULATIONS
    #
    # The population SUM itself does not depend on this;
    # exactextract handles fractional cell coverage.
    #
    # But valid_area_km2 is derived from fractional cell count
    # multiplied by source-cell area.
    # ========================================================

    if not raster_crs.is_projected:

        raise RuntimeError(
            "\nThe GHS-POP raster is in a geographic CRS.\n"
            "\n"
            "Population aggregation can still be performed, "
            "but this script's valid-area calculation assumes "
            "a projected raster with constant cell area.\n"
            "\n"
            f"Raster CRS: {src.crs}\n"
        )


    # --------------------------------------------------------
    # Pixel dimensions in native projected units.
    # --------------------------------------------------------

    pixel_width = abs(
        src.transform.a
    )

    pixel_height = abs(
        src.transform.e
    )


    # --------------------------------------------------------
    # Convert CRS linear units to metres.
    #
    # GHS-POP native projected products normally use metres.
    # --------------------------------------------------------

    axis_info = raster_crs.axis_info


    if not axis_info:

        raise RuntimeError(
            "Could not determine raster CRS units."
        )


    unit_to_metres = (
        axis_info[0].unit_conversion_factor
    )


    pixel_width_m = (
        pixel_width
        *
        unit_to_metres
    )

    pixel_height_m = (
        pixel_height
        *
        unit_to_metres
    )


    pixel_area_km2 = (
        pixel_width_m
        *
        pixel_height_m
        /
        1_000_000.0
    )


    print(
        f"Source pixel width:  "
        f"{pixel_width_m:,.3f} m"
    )

    print(
        f"Source pixel height: "
        f"{pixel_height_m:,.3f} m"
    )

    print(
        f"Source pixel area:   "
        f"{pixel_area_km2:.8f} km²"
    )

    print()


# ============================================================
# REPROJECT POLYGONS TO RASTER CRS
#
# exactextract expects raster and vector geometries to align.
# ============================================================

if gdf.crs != raster_crs:

    print(
        f"Reprojecting PIN codes from "
        f"{gdf.crs} to {raster_crs}..."
    )

    extraction_gdf = gdf.to_crs(
        raster_crs
    )

else:

    extraction_gdf = gdf.copy()


# ============================================================
# EXACT FRACTIONAL-PIXEL EXTRACTION
#
# THIS REPLACES THE OLD BOTTLENECK.
#
# Old algorithm:
#
#   PIN
#     -> Python loop over rows
#       -> Python loop over columns
#         -> construct Shapely pixel polygon
#         -> intersects()
#         -> intersection()
#         -> area()
#
# New algorithm:
#
#   exactextract
#     -> compiled raster/vector intersection
#     -> fractional coverage
#     -> SUM and COUNT
#
#
# exactextract "sum":
#
#   SUM(value * coverage_fraction)
#
# For GHS-POP, whose cell value represents population in the
# whole source cell, this is exactly the desired allocation.
#
#
# exactextract "count":
#
#   Fractional equivalent number of valid source cells.
#
# We use:
#
#   count * pixel_area
#
# to calculate valid source area.
# ============================================================

print()
print(
    "Running exact fractional-pixel population extraction..."
)

print(
    "This should be substantially faster than the "
    "per-pixel Python implementation."
)

print()


stats = exact_extract(
    RASTER_FILE,
    extraction_gdf,
    [
        "sum",
        "count",
    ],
    include_cols=[
        PINCODE_FIELD,
        "district",
    ],
    output="pandas",
)


# ============================================================
# SELECT GHS-POP DATA BAND
#
# Band 1 = population
# Band 2 = alpha/transparency mask
#
# exactextract processes both bands when given the TIFF,
# therefore its output columns are:
#
#   band_1_sum
#   band_2_sum
#   band_1_count
#   band_2_count
#
# We only want Band 1.
# ============================================================

required_columns = [
    "band_1_sum",
    "band_1_count",
]


missing = [
    column
    for column in required_columns
    if column not in stats.columns
]


if missing:

    raise RuntimeError(
        "Missing expected Band 1 exactextract columns: "
        f"{missing}. "
        f"Columns returned: {list(stats.columns)}"
    )


# Drop statistics calculated from the alpha band.

stats = stats[
    [
        PINCODE_FIELD,
        "district",
        "band_1_sum",
        "band_1_count",
    ]
].copy()


stats = stats.rename(
    columns={
        "band_1_sum": "population_2025",
        "band_1_count": "source_pixel_equiv",
    }
)

# ============================================================
# ATTACH PIN-CODE AREAS
# ============================================================

area_lookup = (
    gdf[
        [
            PINCODE_FIELD,
            "_pincode_area_km2",
        ]
    ]
    .copy()
)


stats = stats.merge(
    area_lookup,
    on=PINCODE_FIELD,
    how="left",
    validate="one_to_one",
)


stats = stats.rename(
    columns={
        "_pincode_area_km2":
            "pincode_area_km2"
    }
)


# ============================================================
# DERIVED AREA METRICS
# ============================================================

stats["valid_area_km2"] = (
    stats["source_pixel_equiv"]
    *
    pixel_area_km2
)


stats["coverage_ratio"] = (
    stats["valid_area_km2"]
    /
    stats["pincode_area_km2"]
)


# ------------------------------------------------------------
# Tiny floating-point errors can make a fully covered polygon
# slightly greater than 1.
#
# Do NOT hide substantial >1 errors, however.
# ------------------------------------------------------------

small_overflow = (
    (stats["coverage_ratio"] > 1.0)
    &
    (stats["coverage_ratio"] <= 1.001)
)


stats.loc[
    small_overflow,
    "coverage_ratio"
] = 1.0


# ============================================================
# POPULATION DENSITY
# ============================================================

stats["population_density_km2"] = (
    stats["population_2025"]
    /
    stats["pincode_area_km2"]
)


# ============================================================
# YEAR
# ============================================================

stats["year"] = YEAR


# ============================================================
# COLUMN ORDER
# ============================================================

stats = stats[
    [
        "pincode",
        "district",
        "year",
        "population_2025",
        "pincode_area_km2",
        "population_density_km2",
        "valid_area_km2",
        "coverage_ratio",
        "source_pixel_equiv",
    ]
]


# ============================================================
# SORT
# ============================================================

stats["pincode"] = (
    stats["pincode"]
    .astype(str)
    .str.strip()
)


stats = stats.sort_values(
    "pincode",
    kind="stable",
).reset_index(
    drop=True
)


# ============================================================
# QA CHECKS
# ============================================================

print()
print("Running QA checks...")


# ------------------------------------------------------------
# One row per PIN
# ------------------------------------------------------------

duplicate_count = int(
    stats["pincode"].duplicated().sum()
)


if duplicate_count > 0:

    raise RuntimeError(
        f"Output contains {duplicate_count} "
        "duplicate PIN-code rows."
    )


# ------------------------------------------------------------
# Negative population should never occur.
# ------------------------------------------------------------

negative_population = int(
    (
        stats["population_2025"] < 0
    ).sum()
)


if negative_population > 0:

    raise RuntimeError(
        f"{negative_population} PIN codes have "
        "negative population."
    )


# ------------------------------------------------------------
# Check suspicious coverage.
# ------------------------------------------------------------

high_coverage = stats[
    stats["coverage_ratio"] > 1.001
]


if len(high_coverage) > 0:

    print()
    print(
        "WARNING: Some PIN codes have coverage_ratio > 1.001."
    )

    print(
        "This may indicate that the raster projection is not "
        "equal-area enough for the simple pixel-area QA metric."
    )

    print()

    print(
        high_coverage[
            [
                "pincode",
                "coverage_ratio",
            ]
        ]
        .head(10)
        .to_string(index=False)
    )


# ============================================================
# ROUND OUTPUT
# ============================================================

stats = stats.round(
    {
        "population_2025": 3,
        "pincode_area_km2": 6,
        "population_density_km2": 3,
        "valid_area_km2": 6,
        "coverage_ratio": 6,
        "source_pixel_equiv": 6,
    }
)


# ============================================================
# WRITE CSV
# ============================================================

stats.to_csv(
    OUTPUT_CSV,
    index=False,
)


# ============================================================
# SUMMARY
# ============================================================

print()
print(
    "============================================================"
)

print(
    "GHS-POP aggregation complete"
)

print(
    "============================================================"
)

print(
    f"Unique PIN codes: "
    f"{len(stats):,}"
)


valid_population = int(
    stats["population_2025"]
    .notna()
    .sum()
)


print(
    f"PIN codes with population data: "
    f"{valid_population:,}"
)


total_population = (
    stats["population_2025"]
    .sum()
)


print(
    f"Total allocated population: "
    f"{total_population:,.0f}"
)


print(
    f"Mean coverage ratio: "
    f"{stats['coverage_ratio'].mean():.4f}"
)


print(
    f"Median coverage ratio: "
    f"{stats['coverage_ratio'].median():.4f}"
)


print(
    f"Minimum coverage ratio: "
    f"{stats['coverage_ratio'].min():.4f}"
)


print(
    f"Maximum coverage ratio: "
    f"{stats['coverage_ratio'].max():.4f}"
)


print()
print(
    f"Output: {OUTPUT_CSV}"
)

print()

PY


# ============================================================
# FINISHED
# ============================================================

log "============================================================"
log "GHS-POP aggregation complete"
log "============================================================"

log "Output:"
log "$OUTPUT_CSV"

log ""

log "Preview:"

head -n 6 "$OUTPUT_CSV"