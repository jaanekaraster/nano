#!/usr/bin/env python3

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from collections import deque
from pathlib import Path

import numpy as np


def run(cmd):
    """Run a command and print it."""
    cmd = [str(x) for x in cmd]

    print("+", " ".join(cmd))

    result = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )

    if result.returncode != 0:
        print(result.stdout, file=sys.stderr)
        raise RuntimeError(
            f"Command failed ({result.returncode}): "
            + " ".join(cmd)
        )

    if result.stdout.strip():
        print(result.stdout.rstrip())

    return result.stdout


def require_command(command):
    path = shutil.which(command)

    if path is None:
        raise RuntimeError(
            f"Required command not found: {command}"
        )

    return path


def parse_args():
    parser = argparse.ArgumentParser(
        description="""
Extract high-density regions from a raster.

Pixels >= --high are high-value seeds.

Seeds grow through neighbouring pixels whose values are
> --border.

Pixels <= --border therefore act as barriers.

The resulting regions are polygonized into a GeoPackage.
"""
    )

    parser.add_argument(
        "input",
        help="Input GeoTIFF"
    )

    parser.add_argument(
        "output",
        help="Output GeoPackage"
    )

    parser.add_argument(
        "--high",
        type=float,
        required=True,
        help="High-value seed threshold."
    )

    parser.add_argument(
        "--border",
        type=float,
        required=True,
        help="Low-value barrier threshold."
    )

    parser.add_argument(
        "--min-area",
        type=float,
        default=0,
        help=(
            "Minimum polygon area to keep, in CRS units². "
            "Default: 0."
        )
    )

    parser.add_argument(
        "--connectivity",
        type=int,
        choices=(4, 8),
        default=8,
        help="Pixel connectivity: 4 or 8. Default: 8."
    )

    parser.add_argument(
        "--smooth",
        type=int,
        default=0,
        help=(
            "Mean-filter radius in pixels. "
            "0 = no smoothing, 1 = 3x3, 2 = 5x5, etc."
        )
    )

    parser.add_argument(
        "--layer",
        default="regions",
        help="GeoPackage layer name. Default: regions."
    )

    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Overwrite an existing output."
    )

    return parser.parse_args()


def get_gdal_info(filename):
    """Get gdalinfo JSON."""
    output = run([
        "gdalinfo",
        "-json",
        filename,
    ])

    return json.loads(output)


def read_envi_header(filename):
    """
    Read the minimal information we need from an ENVI header.
    """

    text = Path(filename).read_text()

    values = {}

    for line in text.splitlines():
        if "=" not in line:
            continue

        key, value = line.split("=", 1)

        key = key.strip().lower()
        value = value.strip()

        values[key] = value

    samples = int(values["samples"])
    lines = int(values["lines"])
    data_type = int(values["data type"])
    byte_order = int(values["byte order"])

    if data_type != 5:
        raise RuntimeError(
            f"Expected Float64 ENVI raster (data type 5), "
            f"got data type {data_type}."
        )

    if byte_order == 0:
        dtype = "<f8"
    elif byte_order == 1:
        dtype = ">f8"
    else:
        raise RuntimeError(
            f"Unsupported ENVI byte order: {byte_order}"
        )

    return samples, lines, dtype


def read_raster(input_file, tmpdir):
    """
    Convert the input to Float64 ENVI and read it using NumPy.

    This avoids rasterio and osgeo completely.
    """

    envi_base = Path(tmpdir) / "input"

    run([
        "gdal_translate",
        "-of",
        "ENVI",
        "-b",
        "1",
        "-ot",
        "Float64",
        input_file,
        envi_base,
    ])

    header = Path(str(envi_base) + ".hdr")

    if not header.exists():
        raise RuntimeError(
            f"GDAL did not create expected header: {header}"
        )

    samples, lines, dtype = read_envi_header(
        header
    )

    # ENVI default interleave is BSQ. For one band this is
    # simply a contiguous 2D array.
    array = np.fromfile(
        envi_base,
        dtype=np.dtype(dtype),
    )

    expected = samples * lines

    if array.size != expected:
        raise RuntimeError(
            f"Unexpected raster size: "
            f"expected {expected:,} values, "
            f"got {array.size:,}."
        )

    array = array.reshape(
        (lines, samples)
    )

    return array


def mean_filter(array, radius):
    """
    NaN-aware box filter using integral images.

    radius=1 -> 3x3
    radius=2 -> 5x5
    """

    if radius <= 0:
        return array

    valid = np.isfinite(array)

    values = np.where(
        valid,
        array,
        0.0,
    )

    counts = valid.astype(np.float64)

    pad = radius

    values = np.pad(
        values,
        pad,
        mode="edge",
    )

    counts = np.pad(
        counts,
        pad,
        mode="edge",
    )

    integral_values = (
        values.cumsum(axis=0)
        .cumsum(axis=1)
    )

    integral_counts = (
        counts.cumsum(axis=0)
        .cumsum(axis=1)
    )

    h, w = array.shape

    y0 = np.arange(h)
    y1 = y0 + 2 * pad

    x0 = np.arange(w)
    x1 = x0 + 2 * pad

    total = (
        integral_values[np.ix_(y1, x1)]
        - integral_values[np.ix_(y0, x1)]
        - integral_values[np.ix_(y1, x0)]
        + integral_values[np.ix_(y0, x0)]
    )

    count = (
        integral_counts[np.ix_(y1, x1)]
        - integral_counts[np.ix_(y0, x1)]
        - integral_counts[np.ix_(y1, x0)]
        + integral_counts[np.ix_(y0, x0)]
    )

    result = np.full_like(
        array,
        np.nan,
        dtype=np.float64,
    )

    np.divide(
        total,
        count,
        out=result,
        where=count > 0,
    )

    return result


def grow_regions(allowed, seeds, connectivity):
    """
    Flood-fill from all seed pixels.

    allowed:
        Pixels through which growth may pass.

    seeds:
        Starting pixels.

    Returns:
        Boolean mask of all grown pixels.
    """

    height, width = allowed.shape

    grown = np.zeros_like(
        allowed,
        dtype=bool,
    )

    queue = deque()

    seed_positions = np.argwhere(
        seeds & allowed
    )

    for y, x in seed_positions:
        y = int(y)
        x = int(x)

        grown[y, x] = True
        queue.append((y, x))

    if connectivity == 4:
        neighbours = [
            (-1, 0),
            (1, 0),
            (0, -1),
            (0, 1),
        ]
    else:
        neighbours = [
            (-1, -1),
            (-1, 0),
            (-1, 1),
            (0, -1),
            (0, 1),
            (1, -1),
            (1, 0),
            (1, 1),
        ]

    processed = 0

    while queue:

        y, x = queue.popleft()

        processed += 1

        if processed % 1_000_000 == 0:
            print(
                f"  processed {processed:,} pixels...",
                flush=True,
            )

        for dy, dx in neighbours:

            ny = y + dy
            nx = x + dx

            if ny < 0 or ny >= height:
                continue

            if nx < 0 or nx >= width:
                continue

            if not allowed[ny, nx]:
                continue

            if grown[ny, nx]:
                continue

            grown[ny, nx] = True
            queue.append((ny, nx))

    return grown


def create_mask_raster(
    mask,
    input_file,
    output_file,
    tmpdir,
):
    """
    Write the NumPy mask as a georeferenced GeoTIFF.

    We use the original raster to obtain:
      - CRS
      - extent
      - pixel size
    """

    info = get_gdal_info(input_file)

    coordinate_system = info.get(
        "coordinateSystem",
        {}
    )

    wkt = coordinate_system.get("wkt")

    if not wkt:
        raise RuntimeError(
            "Could not obtain CRS from input raster."
        )

    geotransform = info.get(
        "geoTransform"
    )

    if not geotransform:
        raise RuntimeError(
            "Could not obtain geotransform from input raster."
        )

    height, width = mask.shape

    # Write a raw UInt8 ENVI raster.
    raw = Path(tmpdir) / "mask.raw"
    hdr = Path(str(raw) + ".hdr")

    mask.astype(
        np.uint8
    ).tofile(raw)

    hdr.write_text(
        "\n".join([
            "ENVI",
            f"samples = {width}",
            f"lines = {height}",
            "bands = 1",
            "header offset = 0",
            "file type = ENVI Standard",
            "data type = 1",
            "interleave = bsq",
            "byte order = 0",
        ]) + "\n"
    )

    # We need the four corners for -a_ullr.
    #
    # This assumes a normal north-up raster, which is the overwhelmingly
    # common case for GeoTIFF analysis rasters.
    origin_x = geotransform[0]
    pixel_x = geotransform[1]
    origin_y = geotransform[3]
    pixel_y = geotransform[5]

    if geotransform[2] != 0 or geotransform[4] != 0:
        raise RuntimeError(
            "Input raster has rotated/sheared geotransform. "
            "This script currently expects a north-up raster."
        )

    min_x = origin_x
    max_x = origin_x + width * pixel_x

    max_y = origin_y
    min_y = origin_y + height * pixel_y

    run([
        "gdal_translate",
        "-of",
        "GTiff",
        "-ot",
        "Byte",
        "-a_srs",
        wkt,
        "-a_ullr",
        str(min_x),
        str(max_y),
        str(max_x),
        str(min_y),
        raw,
        output_file,
    ])

    run([
        "gdal_edit.py",
        "-a_nodata",
        "0",
        output_file,
    ])

def polygonize(
    mask_file,
    output_file,
    layer,
    min_area,
    tmpdir,
):
    """
    Polygonize the binary mask.

    The mask has:
        0 = background / NoData
        1 = desired region

    Background is excluded during polygonization.
    """

    # Tell GDAL that zero is NoData.
    #
    # This is preferable to polygonizing zero and then trying
    # to delete the background polygons afterwards.
    run([
        "gdal_edit.py",
        "-a_nodata",
        "0",
        str(mask_file),
    ])

    # GDAL 3.8 syntax:
    #
    # gdal_polygonize.py raster -f GPKG output.gpkg layer field
    run([
        "gdal_polygonize.py",
        str(mask_file),
        "-f",
        "GPKG",
        str(output_file),
        layer,
        "value",
    ])

    # At this point the GeoPackage contains ONLY the grown regions.
    #
    # Optionally remove very small polygons.
    if min_area > 0:

        filtered = Path(tmpdir) / "filtered.gpkg"

        sql = (
            f'SELECT *, ST_Area(geom) AS area '
            f'FROM "{layer}" '
            f'WHERE ST_Area(geom) >= {min_area}'
        )

        run([
            "ogr2ogr",
            "-f",
            "GPKG",
            str(filtered),
            str(output_file),
            "-dialect",
            "SQLite",
            "-sql",
            sql,
            "-nln",
            layer,
        ])

        # Replace original with filtered version.
        os.remove(output_file)
        shutil.copy2(filtered, output_file)

def main():

    args = parse_args()

    if args.high <= args.border:
        raise RuntimeError(
            "--high must be greater than --border."
        )

    if args.smooth < 0:
        raise RuntimeError(
            "--smooth cannot be negative."
        )

    if args.min_area < 0:
        raise RuntimeError(
            "--min-area cannot be negative."
        )

    if not os.path.exists(args.input):
        raise RuntimeError(
            f"Input does not exist: {args.input}"
        )

    if os.path.exists(args.output):

        if not args.overwrite:
            raise RuntimeError(
                f"Output already exists: {args.output}\n"
                "Use --overwrite to replace it."
            )

        os.remove(args.output)

    # Check external dependencies.
    for command in [
        "gdalinfo",
        "gdal_translate",
        "gdal_polygonize.py",
        "ogr2ogr",
    ]:
        require_command(command)

    print()
    print("Raster region extraction")
    print("========================")
    print(f"Input:        {args.input}")
    print(f"Output:       {args.output}")
    print(f"High:         {args.high}")
    print(f"Border:       {args.border}")
    print(f"Connectivity: {args.connectivity}")
    print(f"Smoothing:    {args.smooth}")
    print(f"Min area:     {args.min_area}")
    print()

    with tempfile.TemporaryDirectory(
        prefix="raster_regions_"
    ) as tmpdir:

        print("Reading raster...")
        array = read_raster(
            args.input,
            tmpdir,
        )

        print(
            f"Raster: "
            f"{array.shape[1]:,} x "
            f"{array.shape[0]:,}"
        )

        # Get nodata.
        info = get_gdal_info(
            args.input
        )

        band_info = info.get(
            "bands",
            [{}],
        )[0]

        nodata = band_info.get(
            "noDataValue"
        )

        valid = np.isfinite(array)

        if nodata is not None:
            valid &= array != nodata

        print(
            f"Valid pixels: {valid.sum():,}"
        )

        # Optional smoothing.
        work = array

        if args.smooth > 0:

            print(
                f"Applying "
                f"{2 * args.smooth + 1}x"
                f"{2 * args.smooth + 1} "
                f"mean filter..."
            )

            work = array.copy()
            work[~valid] = np.nan

            work = mean_filter(
                work,
                args.smooth,
            )

            valid = (
                valid
                & np.isfinite(work)
            )

        # High-value pixels are seeds.
        seeds = (
            valid
            & (work >= args.high)
        )

        seed_count = int(
            seeds.sum()
        )

        print(
            f"Seed pixels: {seed_count:,}"
        )

        if seed_count == 0:
            raise RuntimeError(
                "No pixels meet --high."
            )

        # Anything above the border can be crossed.
        allowed = (
            valid
            & (work > args.border)
        )

        print(
            f"Growable pixels: "
            f"{allowed.sum():,}"
        )

        print()
        print("Growing regions...")

        grown = grow_regions(
            allowed,
            seeds,
            args.connectivity,
        )

        print(
            f"Grown pixels: "
            f"{grown.sum():,}"
        )

        # Create binary georeferenced raster.
        mask_file = Path(tmpdir) / "regions.tif"

        print()
        print("Creating mask raster...")

        create_mask_raster(
            grown,
            args.input,
            mask_file,
            tmpdir,
        )

        print()
        print("Polygonizing...")

        polygonize(
            mask_file,
            args.output,
            args.layer,
            args.min_area,
            tmpdir,
        )

    print()
    print("Finished.")
    print(f"Output: {args.output}")


if __name__ == "__main__":

    try:
        main()

    except KeyboardInterrupt:
        print(
            "\nInterrupted.",
            file=sys.stderr,
        )
        sys.exit(130)

    except Exception as exc:
        print(
            f"\nERROR: {exc}",
            file=sys.stderr,
        )
        sys.exit(1)