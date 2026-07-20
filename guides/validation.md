# Validation

Reach 2.x is validated at multiple levels.

## Project gates

```bash
mix compile --force --warnings-as-errors
mix ci
mix docs
mix hex.build
```

`mix ci` includes formatting, JavaScript checks, Credo/ExSlop, ExDNA duplication checks, architecture policy, Dialyzer, and tests.

## Canonical CLI validation

Checked-in canonical command tests exercise command routing, canonical envelopes, graph-backed candidates, and JSON purity.

```bash
mix test test/reach/cli/canonical_tasks_test.exs test/reach/cli/json_output_test.exs
```

## ProgramFacts oracle validation

Reach uses ProgramFacts-generated Elixir projects and oracle facts to validate call graphs, layouts, data flow, effects, architecture policies, branch/control-flow policies, and syntax policies.

## Exograph corpus calibration

From a Reach source checkout, repository-only calibration tooling can consume Exograph's versioned query and hydration APIs without making Exograph execute Reach analyzers. This tooling is isolated from the shipped Reach runtime and Hex package:

```bash
cd dev/calibration
mix calibration.run \
  --base-url http://localhost:4200 \
  --limit 25 \
  --kinds dual_key_fallback,false_collapsing_lookup \
  --output /tmp/reach-calibration.json
```

When indexed prefilters are available, Reach hydrates only the candidate files
returned by Exograph. Pass one or more `--paths` globs to override that scope;
queries without indexed prefilters fall back to `lib/**`.

Each finding receives a stable review ID. Supply a JSON object mapping those IDs
to `true_positive` or `false_positive` with `--labels`; the report then includes
reviewed precision per smell kind. Snapshot fingerprints and package versions
make reviewed samples reproducible.

## Block quality

Visualization changes must preserve source coverage, disjoint block ranges, branch boundaries, clause blocks, non-empty labels, connected exits, and no duplicated lines.

```bash
mix test test/reach/visualize/block_quality_test.exs
```
