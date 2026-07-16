# Total-function laundering v2 full review

Configuration:

- Seed: `total-function-laundering-v2-full`
- Candidate pool limit: 200 per structural prefilter
- Selected package versions: 210
- Candidate pool size: 210
- Detector: `total_function_laundering`
- Prefilters: `_ when _ in [_, _]` and `defp _(_), do: _`
- Report: `../reports/total-function-laundering-v2-full.json`

Results:

- 0 hydration or analysis errors
- 0 findings
- No label file was created because the run produced no finding IDs to review.

The guarded-domain-only prefilter was also run over all 299 package versions in its fetched candidate pool and produced no findings. Adding the private unary-function prefilter broadened the candidate set to cover the detector's unguarded literal-clause form. The combined run analyzed every package version in the fetched pool and still produced no corpus findings.

This establishes an initial no-noise corpus result, not a precision estimate: there is no reviewed positive denominator. The detector remains covered by its synthetic positive fixtures and historical local specimen. The per-pattern candidate cap means this is not an exhaustive scan of every private unary function in the full corpus.
