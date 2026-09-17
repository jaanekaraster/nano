## Local layer browser

The MVP is available in `index.html`. It uses MapLibre GL JS and discovers supported files from `data/` when served over HTTP.

```sh
npx serve . -l 8000
```

Open http://localhost:8000. Add GeoJSON or GeoTIFF files to `data/` and reload the page to make them available as selectable layers. The current COG is `data/processed/pmtiles/`.

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
