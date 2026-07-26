# JSON Output

All canonical commands support `--format json` for automation.

```bash
mix reach.map --format json
mix reach.inspect MyApp.Accounts.create_user/1 --context --format json
mix reach.trace --from conn.params --to Repo --format json
mix reach.check --arch --format json
mix reach.otp --format json
```

JSON output is pipe-safe and should not include progress text. Tests decode complete captured output to prevent regressions.

Prefer JSON for agents and CI. Human text output is intentionally summarized, colorized, and may include truncation hints.

Project-backed `reach.check` results include an `analysis` object with `mix_env`, `source`, `source_roots`, and `file_count`. Use it to verify that local and CI checks analyzed the same scope; `source: "paths"` indicates an explicit `--path` or `checks[:source_paths]` scope independent of `MIX_ENV`.

Contract candidates include structured `canonical_site`, `keys`, `draft_contract`, and `blast_radius` fields in addition to the common candidate proof and suggestion fields. `canonical_site` names an existing producer, literal construction function, or normalization boundary proven from source; it remains `null` when Reach cannot prove one. Decoded-boundary candidates also include `decoder` and `boundary`. Agents should treat `draft_contract` as a starting shape, review every function listed in `blast_radius`, and complete every proof step before editing.

Smell findings include `remediation_safety`: `equivalent` means Reach has a behavior-preserving replacement contract, `conditional` requires stated preconditions, and `review_only` is advisory evidence rather than an automatic rewrite. Agents must not turn `conditional` or `review_only` findings into edits without proving the missing conditions.

Changed-code results include top-level `risk` and `confidence` fields plus a detailed `coverage` object:

```json
{
  "command": "reach.check",
  "risk": "low",
  "confidence": "partial",
  "suppression_report": {
    "added": [
      {
        "scope": "next_line",
        "tokens": ["default_drift"],
        "reason": "legacy boundary",
        "file": "lib/model.ex",
        "line": 12,
        "target_line": 13
      }
    ],
    "removed": [],
    "reasonless_added": [],
    "unchanged_count": 1,
    "total_before": 1,
    "total_after": 2
  },
  "displaced_facts": [
    {
      "family": "dual_key_contract",
      "status": "displaced",
      "fingerprint": "sha256:...",
      "key": "name",
      "old_locations": [{"file": "lib/model.ex", "line": 20}],
      "new_locations": [{"file": "lib/model.ex", "line": 35}],
      "occurrences_before": 2,
      "occurrences_after": 2
    }
  ],
  "strictness_downgrades": [
    {
      "kind": "field_to_get",
      "module": "MyApp.State",
      "function": "search",
      "arity": 1,
      "key": "search",
      "file": "lib/my_app/state.ex",
      "old_line": 14,
      "new_line": 14,
      "malformed_callers": []
    }
  ],
  "shape_entropy_regressions": [
    {
      "target": "MyApp.Processor.process/1",
      "parameter": "entity",
      "old_entropy": 0.0,
      "new_entropy": 0.8,
      "delta": 0.8,
      "old_variants": [["email", "id", "name"]],
      "new_variants": [["email", "id", "name"], ["id", "role", "status"]]
    }
  ],
  "coverage": {
    "coverage_percent": 72.5,
    "changed_line_count": 40,
    "assessed_line_count": 29,
    "unassessed_line_count": 11,
    "fully_assessed_file_count": 2,
    "partially_assessed_file_count": 1,
    "unassessed_file_count": 1,
    "unassessed_files": ["README.md", "lib/removed.ex"]
  }
}
```

Risk summarizes assessed functions and high-confidence changed-code erosion events. `strictness_downgrades` reports required field access, `Map.fetch!/2`, or required map patterns replaced by lenient `Map.get/2,3`. `shape_entropy_regressions` reports changed callers that widen a consumed parameter's fixed-map contract. `displaced_facts` reports stable evidence identities that moved without reducing their occurrence count. `suppression_report` distinguishes added, removed, unchanged, and reasonless source directives. Check `confidence`, `coverage_percent`, and `unassessed_files` before using risk in automation.
