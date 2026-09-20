## Local layer browser

The MVP is available in `index.html`. It uses MapLibre GL JS and discovers supported files from `data/` when served over HTTP.

```sh
npx serve . -l 8000
```

Open http://localhost:8000. Add GeoJSON or GeoTIFF files to `data/` and reload the page to make them available as selectable layers. The current COG is `data/processed/pmtiles/`.


## Pipeline for ingesting data and showing it on the map
1. Get data from R2
This gets the raw, complete file from R2. 
```
./scripts/get_from_r2.sh <file.tif>
```

2. Clip the downloaded file
This clips the file to a specified polygon boundary as a subset.
```
./scripts/clip_downloaded_file.sh <file.tif> <clip_boundary.geojson>
```

3. Build PMTiles for the clipped rasters
This reduces the filesize. 
```
./scripts/build_pmtiles.sh
```

4. Get updated CSV parquet file and format it

```
./scripts/build_pincode_activity.sh
./scripts/add_general_category.sh
./scripts/aggregate_pincode_general.sh
./

5. Gather into densest area clusters
First check the distribution of the pixels to determine the right cutoff: 
```
uv run python -c "
import rasterio, numpy as np
with rasterio.open('data/processed/clipped/built_s_2025.tif') as src:
    d = src.read(1)
for v in [1, 10, 50, 100, 500, 1000, 5000]:
    pct = 100 * (d >= v).sum() / d.size
    print(f'>= {v:>6}: {pct:.2f}% of pixels')
"
```
```
# Population
uv run python ./scripts/nonzero_to_gpkg.py data/processed/clipped/pop_2025_cog.tif pop_2025_urban.geojson     --resample 10 --dissolve --tolerance 500     --min-value 200 --min-area 1000000 --overwrite
```
```
# BUILT-S
```
uv run python ./scripts/nonzero_to_gpkg.py data/processed/clipped/built_s_2025.tif built_s_2025_urban.geojson     --resample 10 --dissolve --tolerance 500 --min-area 1000000     --min-value 5000 --overwrite

 uv run python ./scripts/nonzero_to_gpkg.py data/processed/clipped/built_s_2025_2000_cog.tif built_s_2025_2000_urban.geojson     --resample 10 --dissolve --tolerance 500
 --min-area 1000000     --min-value 5000 --overwrite
```

## BUILT-S-NRES
```
uv run python ./scripts/nonzero_to_gpkg.py data/processed/clipped/built_s_nres_2025_2000_cog.tif built_s_nres_2025_2000_urban.geojson     --resample 5 --dissolve --tolerance 200 --min-area 500000     --min-value 10 --overwrite
```

## Nightlights
```
uv run python ./scripts/nonzero_to_gpkg.py data/processed/clipped/nightlights_west_india_2025_cog.tif nightlights_west_india_2025_urban.geojson     --resample 1 --tolerance 0 --min-area 0 \
    --min-value 10 --overwrite
```

## Raster PMTiles

Heavy raster layers are served as colorized raster PMTiles. The build reads TIFFs from `data/processed/` and writes one PMTiles file per layer to `data/processed/pmtiles/`. Rebuild them after changing a clipped raster or its ramp configuration:

```sh
PMTILES_BIN=/path/to/pmtiles scripts/build_pmtiles.sh
```

The browser reads `data/layers.json` for PMTiles URLs, titles, citations, value ranges, and layer styling. Raster colors are baked into the tiles during the build, while the manifest keeps the UI legend consistent. The build converts every `.tif` and `.tiff` in `data/processed/clipped/` and writes PMTiles to `data/processed/pmtiles/`.

### Download and clip a raster

Download a GeoTIFF from the configured R2 bucket into `data/raw/`:

```sh
scripts/get_from_r2.sh geotiff/example.tif
```

Clip it to the Maharashtra boundary and move the result to `data/processed/clipped/`:

```sh
scripts/clip_downloaded_file.sh example.tif districts/maharashtra_boundary.geojson
```

The clip script removes the raw input only after GDAL completes successfully. The R2 bucket and AWS CLI profile can be overridden with `R2_BUCKET` and `AWS_PROFILE`.

## State district GeoJSON

Extract a state's districts and a dissolved state boundary from the India district GeoJSON:

```sh
scripts/get_state_districts.sh "Maharashtra"
```

The script downloads and caches the all-India source under `build/districts/` and writes `data/districts/maharashtra_districts.geojson` and `data/districts/maharashtra_boundary.geojson`.
