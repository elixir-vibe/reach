# Reach Calibration

This development-only Mix project calibrates Reach detectors against external source corpora. It is intentionally excluded from the Reach runtime and Hex package.

## Run

```bash
mix deps.get
mix calibration.run \
  --base-url http://localhost:4200 \
  --limit 25 \
  --kinds dual_key_fallback,false_collapsing_lookup \
  --output /tmp/reach-calibration.json
```

Configuration is validated by `ReachCalibration.Config` through NimbleOptions. Indexed candidate selection is deterministic for a given `--seed` and `--candidate-limit`. Exograph transport, source hydration, labels, and precision reports belong to this project rather than Reach core.

Use repeated `--paths` options to override candidate-scoped hydration. Without explicit paths, indexed candidate files are hydrated; selections without indexed prefilters fall back to `lib/**`.

## Validate

```bash
mix ci
```
