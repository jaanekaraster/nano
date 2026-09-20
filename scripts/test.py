#!/usr/bin/env python3
"""
Convert non-zero pixels in a raster into simplified, dissolved polygons
suitable for display at zoomed-out scales.

Pipeline:
  1. (Optional) Downsample the raster to a coarser resolution
  2. Build a binary non-zero mask
  3. Polygonize connected regions
  4. Validate & fix geometries
  5. Dissolve all touching/overlapping polygons into blobs
  6. Simplify outlines
  7. Drop polygons below a minimum area threshold
  8. Write to GeoPackage or GeoJSON

Dependencies:
    uv add rasterio shapely fiona numpy tqdm
"""

import argparse
import sys
from pathlib import Path

import numpy as np


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Convert non-zero pixels in a raster into simplified, "
            "dissolved polygons for zoomed-out map display."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
examples:
  # Full pipeline: 10x downsample, dissolve, simplify outlines by 500 m,
  # drop blobs smaller than 1 km²
  python nonzero_to_gpkg.py pop.tif out.gpkg \\
      --resample 10 --dissolve --tolerance 500 --min-area 1000000

  # Just dissolve and simplify, no downsampling
  python nonzero_to_gpkg.py pop.tif out.gpkg --dissolve --tolerance 200

  # High-precision output (original behaviour)
  python nonzero_to_gpkg.py pop.tif out.gpkg
""",
    )

    parser.add_argument("input",  help="Input TIFF")
    parser.add_argument("output", help="Output file (.gpkg or .geojson)")

    parser.add_argument(
        "--band",
        type=int,
        default=1,
        help="Raster band to process. Default: 1",
    )
    parser.add_argument(
        "--connectivity",
        type=int,
        choices=(4, 8),
        default=8,
        help="Pixel connectivity (4 or 8). Default: 8",
    )
    parser.add_argument(
        "--layer",
        default="nonzero",
        help="Output layer name (GeoPackage only). Default: nonzero",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Replace an existing output file.",
    )

    # --- Simplification levers ---
    g = parser.add_argument_group("simplification")

    g.add_argument(
        "--resample",
        type=int,
        default=1,
        metavar="FACTOR",
        help=(
            "Downsample the raster by this factor before polygonizing. "
            "E.g. --resample 10 makes each output pixel 10x larger. "
            "Uses max resampling so any non-zero presence is preserved. "
            "Default: 1 (no downsampling)."
        ),
    )
    g.add_argument(
        "--dissolve",
        action="store_true",
        help=(
            "Merge all touching or overlapping polygons into single blobs. "
            "Removes internal boundaries between adjacent pixel-polygons. "
            "Strongly recommended for large datasets."
        ),
    )
    g.add_argument(
        "--tolerance",
        type=float,
        default=0.0,
        metavar="UNITS",
        help=(
            "Simplify polygon outlines using the Douglas-Peucker algorithm. "
            "Value is in the CRS units (metres for projected, degrees for geographic). "
            "E.g. --tolerance 500 for a 500 m simplification. Default: 0 (no simplification)."
        ),
    )
    g.add_argument(
        "--min-area",
        type=float,
        default=0.0,
        metavar="UNITS²",
        help=(
            "Drop polygons whose area is below this threshold (CRS units²). "
            "E.g. --min-area 1000000 drops blobs smaller than 1 km². Default: 0."
        ),
    )
    g.add_argument(
        "--min-value",
        type=float,
        default=0.0,
        metavar="VALUE",
        help=(
            "Only include pixels whose value is >= this threshold before "
            "polygonizing. E.g. --min-value 100 ignores pixels with a value "
            "below 100. Raise this to filter out sparse/low-density pixels "
            "and retain only dense regions. Default: 0 (any non-zero pixel)."
        ),
    )

    return parser.parse_args()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def section(title):
    print()
    print(title)
    print("=" * len(title))


def check_imports():
    missing = []
    for pkg in ("rasterio", "shapely", "fiona", "numpy", "tqdm"):
        try:
            __import__(pkg)
        except ImportError:
            missing.append(pkg)
    if missing:
        print(
            "ERROR: Missing dependencies. Install with:\n"
            f"  uv add {' '.join(missing)}",
            file=sys.stderr,
        )
        sys.exit(1)


def detect_driver(output_path):
    suffix = output_path.suffix.lower()
    if suffix == ".gpkg":
        return "GPKG"
    if suffix in (".geojson", ".json"):
        return "GeoJSON"
    raise RuntimeError(
        f"Unknown output extension '{suffix}'. Use .gpkg or .geojson."
    )


# ---------------------------------------------------------------------------
# Raster helpers
# ---------------------------------------------------------------------------

def resample_to_array(src, band_index, factor):
    """
    Read band at 1/factor resolution using a manual block-max,
    so any non-zero pixel in the source block is preserved.
    Returns (data_array, new_transform).

    Pads the raster to an exact multiple of factor rather than
    trimming, so no edge rows/columns are lost.
    """
    full = src.read(band_index)
    h, w = full.shape

    # Pad to the next exact multiple of factor on both axes.
    h_pad = (-h % factor)  # 0 if already a multiple
    w_pad = (-w % factor)

    if h_pad > 0 or w_pad > 0:
        # Pad with zeros (treated as no-data / non-contributing).
        full = np.pad(full, ((0, h_pad), (0, w_pad)), mode="constant", constant_values=0)

    h_new, w_new = full.shape
    out_height = h_new // factor
    out_width  = w_new // factor

    # Reshape into blocks and take the max within each block.
    data = (
        full
        .reshape(out_height, factor, out_width, factor)
        .max(axis=(1, 3))
    )

    # Recalculate the affine transform for the coarser grid.
    # Scale by factor exactly — this keeps the output grid aligned
    # with the source origin regardless of padding.
    from rasterio.transform import Affine
    t = src.transform
    new_transform = Affine(
        t.a * factor,  # pixel width  * factor
        t.b,
        t.c,           # top-left x unchanged
        t.d,
        t.e * factor,  # pixel height * factor (negative)
        t.f,           # top-left y unchanged
    )

    return data, new_transform
    return data, new_transform


def build_mask(data, nodata, min_value=0.0):
    """
    True wherever pixel value is > 0 (or >= min_value if specified)
    and is not the nodata value.
    """
    if min_value > 0:
        mask = data >= min_value
    else:
        mask = data != 0

    if nodata is not None:
        try:
            if np.isnan(nodata):
                mask &= ~np.isnan(data)
            else:
                mask &= data != nodata
        except (TypeError, ValueError):
            mask &= data != nodata
    return mask.astype(np.uint8)


# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------

def polygonize_mask(data, mask, transform, connectivity):
    from rasterio.features import shapes
    from shapely.geometry import shape

    for geom_dict, value in shapes(
        data,
        mask=mask,
        connectivity=connectivity,
        transform=transform,
    ):
        yield shape(geom_dict), value


def fix_geometry(geom):
    if geom.is_valid:
        return geom
    try:
        from shapely.validation import make_valid
        fixed = make_valid(geom)
    except ImportError:
        fixed = geom.buffer(0)
    except Exception:
        try:
            fixed = geom.buffer(0)
        except Exception:
            return None
    return None if (fixed is None or fixed.is_empty) else fixed


def iter_polygons(geom):
    """Yield only Polygon parts from any geometry type."""
    from shapely.geometry import Polygon, MultiPolygon, GeometryCollection
    if isinstance(geom, Polygon):
        if not geom.is_empty:
            yield geom
    elif isinstance(geom, (MultiPolygon, GeometryCollection)):
        for part in geom.geoms:
            yield from iter_polygons(part)


def dissolve(geometries):
    """
    Union all geometries into a single (possibly Multi) geometry,
    then flatten back to individual polygons.

    Works in batches to avoid building one giant union tree.
    """
    from shapely.ops import unary_union

    section("STEP 5: Dissolving polygons")
    print(f"  Unioning {len(geometries):,} polygons into blobs...")

    # unary_union is the most efficient bulk union in shapely.
    merged = unary_union(geometries)

    polys = list(iter_polygons(merged))
    print(f"  Blobs after dissolve: {len(polys):,}")
    return polys


def simplify_polygon(poly, tolerance, preserve_topology=True):
    """Simplify and re-validate."""
    if tolerance <= 0:
        return poly
    simplified = poly.simplify(tolerance, preserve_topology=preserve_topology)
    if simplified.is_empty:
        return None
    fixed = fix_geometry(simplified)
    return fixed


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    check_imports()

    import rasterio
    import fiona
    from shapely.geometry import mapping
    from tqdm import tqdm

    args = parse_args()
    input_path  = Path(args.input)
    output_path = Path(args.output)

    if not input_path.exists():
        print(f"ERROR: Input not found: {input_path}", file=sys.stderr)
        sys.exit(1)

    if output_path.exists():
        if args.overwrite:
            print(f"Removing existing output: {output_path}")
            output_path.unlink()
        else:
            print(
                f"ERROR: Output exists: {output_path}\nUse --overwrite.",
                file=sys.stderr,
            )
            sys.exit(1)

    driver = detect_driver(output_path)

    # ------------------------------------------------------------------
    # STEP 1 — Inspect & (optionally) downsample
    # ------------------------------------------------------------------

    section("STEP 1: Inspecting input raster")

    with rasterio.open(input_path) as src:

        print(f"File:       {input_path}")
        print(f"Size:       {src.width} x {src.height} px")
        print(f"Bands:      {src.count}")
        print(f"Dtype:      {src.dtypes[args.band - 1]}")
        print(f"CRS:        {src.crs}")
        print(f"NoData:     {src.nodata}")
        print(f"Pixel size: {abs(src.transform.a):.4f} x {abs(src.transform.e):.4f} CRS units")

        if src.crs is None:
            print("ERROR: No CRS on input raster.", file=sys.stderr)
            sys.exit(1)

        if args.band < 1 or args.band > src.count:
            print(f"ERROR: --band {args.band} out of range.", file=sys.stderr)
            sys.exit(1)

        crs_wkt = src.crs.to_wkt()
        nodata  = src.nodata

        if args.resample > 1:
            section(f"STEP 2: Downsampling by {args.resample}x (MAX resampling)")
            data, transform = resample_to_array(src, args.band, args.resample)
            orig_px = abs(src.transform.a)
            new_px  = abs(transform.a)
            print(f"  Original size:  {src.width} x {src.height} px  ({orig_px:.2f} CRS units/px)")
            print(f"  Resampled size: {data.shape[1]} x {data.shape[0]} px  ({new_px:.2f} CRS units/px)")

            # Verify the resampled extent matches the source.
            from rasterio.transform import array_bounds
            rb = array_bounds(data.shape[0], data.shape[1], transform)
            print(f"  Source extent:   L={src.bounds.left} R={src.bounds.right} T={src.bounds.top} B={src.bounds.bottom}")
            print(f"  Resampled extent: L={rb[0]:.1f} R={rb[2]:.1f} T={rb[3]:.1f} B={rb[1]:.1f}")
        else:
            section("STEP 2: Reading raster band")
            data      = src.read(args.band)
            transform = src.transform
            print(f"  Size: {data.shape[1]} x {data.shape[0]} px (no downsampling)")

    # ------------------------------------------------------------------
    # STEP 3 — Build mask
    # ------------------------------------------------------------------

    section("STEP 3: Building non-zero mask")

    if args.min_value > 0:
        print(f"  Value threshold: >= {args.min_value} (pixels below this are excluded)")
    else:
        print("  Value threshold: any non-zero pixel (use --min-value N to raise)")

    mask = build_mask(data, nodata, min_value=args.min_value)
    nonzero_px = int(mask.sum())
    total_px   = data.shape[0] * data.shape[1]
    print(f"  Pixels passing threshold: {nonzero_px:,} / {total_px:,}  ({100*nonzero_px/max(total_px,1):.1f}%)")

    if nonzero_px == 0:
        print("WARNING: No non-zero pixels found. Output will be empty.")

    # ------------------------------------------------------------------
    # STEP 4 — Polygonize
    # ------------------------------------------------------------------

    section("STEP 4: Polygonizing")
    print(f"  Connectivity: {args.connectivity}")

    raw = list(
        tqdm(
            polygonize_mask(data, mask, transform, args.connectivity),
            desc="  Extracting",
            unit=" poly",
        )
    )
    print(f"  Raw polygons: {len(raw):,}")

    # Validate & fix immediately; collect just the geometries for dissolve.
    geometries  = []
    n_valid     = 0
    n_fixed     = 0
    n_unfixable = 0

    for geom, _value in tqdm(raw, desc="  Validating", unit=" poly"):
        was_valid = geom.is_valid
        fixed = fix_geometry(geom)
        if fixed is None:
            n_unfixable += 1
            continue
        for poly in iter_polygons(fixed):
            if not poly.is_valid:
                poly = poly.buffer(0)
            if poly.is_valid and not poly.is_empty:
                geometries.append(poly)
                if was_valid:
                    n_valid += 1
                else:
                    n_fixed += 1
            else:
                n_unfixable += 1

    print(f"  Already valid: {n_valid:,}")
    print(f"  Fixed:         {n_fixed:,}")
    print(f"  Unfixable:     {n_unfixable:,}")
    print(f"  Kept:          {len(geometries):,}")

    # ------------------------------------------------------------------
    # STEP 5 — Dissolve (optional)
    # ------------------------------------------------------------------

    if args.dissolve and geometries:
        geometries = dissolve(geometries)
    else:
        section("STEP 5: Dissolve skipped (use --dissolve to enable)")

    # ------------------------------------------------------------------
    # STEP 6 — Simplify + filter
    # ------------------------------------------------------------------

    section("STEP 6: Simplifying and filtering")

    if args.tolerance > 0:
        print(f"  Simplification tolerance: {args.tolerance} CRS units")
    else:
        print("  No simplification (use --tolerance N to enable)")

    if args.min_area > 0:
        print(f"  Minimum area: {args.min_area:,.0f} CRS units²")
    else:
        print("  No area filter (use --min-area N to enable)")

    final_features = []
    n_simplified   = 0
    n_too_small    = 0
    n_degenerate   = 0

    for poly in tqdm(geometries, desc="  Processing", unit=" poly"):

        # Area filter first (cheap).
        if args.min_area > 0 and poly.area < args.min_area:
            n_too_small += 1
            continue

        # Simplify.
        if args.tolerance > 0:
            result = simplify_polygon(poly, args.tolerance)
            if result is None:
                n_degenerate += 1
                continue
            # Flatten — simplify can turn a Polygon into a MultiPolygon.
            parts = list(iter_polygons(result))
        else:
            parts = [poly]

        for part in parts:
            # Apply area filter again after simplification.
            if args.min_area > 0 and part.area < args.min_area:
                n_too_small += 1
                continue
            final_features.append(part)
            if args.tolerance > 0:
                n_simplified += 1

    print(f"  Simplified:  {n_simplified:,}")
    print(f"  Too small:   {n_too_small:,}")
    print(f"  Degenerate:  {n_degenerate:,}")
    print(f"  Final count: {len(final_features):,}")

    if not final_features:
        print("ERROR: No polygons survived filtering.", file=sys.stderr)
        sys.exit(1)

    # ------------------------------------------------------------------
    # STEP 7 — Write output
    # ------------------------------------------------------------------

    section("STEP 7: Writing output")
    print(f"  Format: {driver}")
    print(f"  File:   {output_path}")

    schema = {
        "geometry": "Polygon",
        "properties": {},
    }

    # World Mollweide often lacks an EPSG authority entry in the WKT,
    # which causes QGIS to fail to recognise the CRS. Detect it by name
    # and substitute the canonical EPSG:54009 / ESRI:54009 authority so
    # QGIS can match it correctly.
    if "mollweide" in crs_wkt.lower():
        print("  Detected World Mollweide — writing CRS as EPSG:54009")
        try:
            import pyproj
            fiona_crs = fiona.crs.CRS.from_epsg(54009)
        except Exception:
            # pyproj may not know 54009 by EPSG; fall back to ESRI WKT.
            fiona_crs = fiona.crs.CRS.from_wkt(
                'PROJCS["World_Mollweide",'
                'GEOGCS["GCS_WGS_1984",'
                'DATUM["WGS_1984",'
                'SPHEROID["WGS_1984",6378137.0,298.257223563]],'
                'PRIMEM["Greenwich",0.0],'
                'UNIT["Degree",0.0174532925199433]],'
                'PROJECTION["Mollweide"],'
                'PARAMETER["False_Easting",0.0],'
                'PARAMETER["False_Northing",0.0],'
                'PARAMETER["Central_Meridian",0.0],'
                'UNIT["Meter",1.0],'
                'AUTHORITY["ESRI","54009"]]'
            )
    else:
        fiona_crs = fiona.crs.CRS.from_wkt(crs_wkt)

    layer_kwargs = {"layer": args.layer} if driver == "GPKG" else {}

    with fiona.open(
        output_path,
        mode="w",
        driver=driver,
        crs=fiona_crs,
        schema=schema,
        **layer_kwargs,
    ) as dst:
        for poly in tqdm(final_features, desc="  Writing", unit=" poly"):
            dst.write({
                "type": "Feature",
                "geometry": mapping(poly),
                "properties": {},
            })

    # ------------------------------------------------------------------
    # STEP 8 — Final check
    # ------------------------------------------------------------------

    section("STEP 8: Verifying output")

    size = output_path.stat().st_size
    print(f"  File size: {size:,} bytes  ({size/1_048_576:.1f} MB)")

    open_kwargs = {"layer": args.layer} if driver == "GPKG" else {}
    with fiona.open(output_path, **open_kwargs) as f:
        count  = len(f)
        crs_ok = f.crs is not None

    print(f"  Features:  {count:,}")
    print(f"  CRS:       {'present ✓' if crs_ok else 'MISSING ✗'}")

    if count == 0:
        print("ERROR: Output is empty.", file=sys.stderr)
        sys.exit(1)

    # ------------------------------------------------------------------
    # Summary
    # ------------------------------------------------------------------

    print()
    print("SUCCESS")
    print("-------")
    print(f"  Output:      {output_path}")
    if driver == "GPKG":
        print(f"  Layer:       {args.layer}")
    print(f"  Features:    {count:,}")
    print(f"  File size:   {size/1_048_576:.1f} MB")
    if args.resample > 1:
        print(f"  Resampled:   {args.resample}x")
    if args.dissolve:
        print(f"  Dissolved:   yes")
    if args.tolerance > 0:
        print(f"  Simplified:  tolerance={args.tolerance}")
    if args.min_value > 0:
        print(f"  Min value:   {args.min_value}")
    if args.min_area > 0:
        print(f"  Min area:    {args.min_area:,.0f} CRS units²")
    print()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nInterrupted.", file=sys.stderr)
        sys.exit(130)
    except Exception as exc:
        print(f"\nERROR: {exc}", file=sys.stderr)
        sys.exit(1)