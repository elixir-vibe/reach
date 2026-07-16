# Map-contract baseline v1 review

Configuration:

- Seed: `map-contract-baseline-v1`
- Candidate pool limit: 5,000
- Selected package versions: 100
- Candidate pool size: 734
- Detectors: `dual_key_fallback`, `false_collapsing_lookup`
- Baseline report: `../reports/map-contract-baseline-v1.json`
- Post-tuning report: `../reports/map-contract-baseline-v1-post-tune.json`

Review results:

- All 15 `dual_key_fallback` findings are true positives. Each location performs an atom/string representation fallback over the same logical map field.
- All 3 `false_collapsing_lookup` findings are false positives. The affected values are required object/configuration fields where `false` is not a valid present value:
  - `cmdc_gateway` working-directory root configuration
  - `baileys_ex` required message key
  - `baileys_ex` required key field

The false-collapsing detector therefore requires stronger boolean-domain evidence rather than a global threshold adjustment. After adding boolean key, predicate-function, or literal boolean-default evidence, the same corpus and seed retained all 15 reviewed dual-key findings and suppressed all 3 reviewed false-collapsing false positives.
