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

Changed-code results include top-level `risk` and `confidence` fields plus a detailed `coverage` object:

```json
{
  "command": "reach.check",
  "risk": "low",
  "confidence": "partial",
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

Risk only summarizes assessed functions. Check `confidence`, `coverage_percent`, and `unassessed_files` before using that risk in automation.
