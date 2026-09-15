## Work Plan

- Load in the layer files dynamically from the R2 bucket
OR
- Copy the COG files for now to create an MVP

## Local layer browser

The MVP is available in `index.html`. It uses MapLibre GL JS and discovers supported files from `data/` when served over HTTP.

```sh
npx serve . -l 8000
```

Open http://localhost:8000. Add GeoJSON or GeoTIFF files to `data/` and reload the page to make them available as selectable layers. The current COG is `data/aurangabad_built_s_nres_2025_2000_cog.tif`.

## Raster PMTiles

Heavy raster layers are served as colorized raster PMTiles. Rebuild them after changing a clipped raster or its ramp configuration:

```sh
PMTILES_BIN=/path/to/pmtiles scripts/build_pmtiles.sh
```

The browser reads `data/layers.json` for PMTiles URLs, titles, citations, value ranges, and layer styling. Raster colors are baked into the tiles during the build, while the manifest keeps the UI legend consistent.

## State district GeoJSON

Extract a state's districts and a dissolved state boundary from the India district GeoJSON:

```sh
scripts/get_state_districts.sh "Maharashtra"
```

The script downloads and caches the all-India source under `build/districts/` and writes `data/districts/maharashtra_districts.geojson` and `data/districts/maharashtra_boundary.geojson`.
