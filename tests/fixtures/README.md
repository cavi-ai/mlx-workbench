# Shared contract fixtures

One fixture set consumed by BOTH test suites — the Python web UI
(`tests/test_contract_fixtures.py`) and the native app
(`mlx-mac/mlx-macTests/ScanContractTests.swift` and
`ContractFixtureTests.swift`). If a contract changes, change the fixture and
both suites must keep passing; a failure on either side is a drift signal,
not a test bug.

| Fixture | Contract | Consumers |
| --- | --- | --- |
| `convert-scan-valid.json` | Unwrapped `convert scan` data payload a UI may render | `bridge.validate_scan` (Python), `WorkbenchAPI.decodeScan` (Swift) |
| `convert-scan-missing-bytes.json` | Scan payload missing a required per-model byte count; both sides must reject it | same |
| `config-premium-keys.json` | `config.json` containing keys written by the native app's premium toggles; a load/save cycle must preserve them | `config.load`/`save` (Python), `ConfigModule` (Swift) |
| `quarantine-ledger.jsonl` | Quarantine ledger lines (`moved_at`/`from`/`to`/`bytes`, newest last) | `quarantine.ledger` (Python), `Quarantine.ledger` (Swift) |

Rules:

- Fixtures are data payloads, not transport envelopes (no `status`/`error`
  wrapper), because both sides validate the unwrapped data.
- Keep values distinctive (non-default) so preservation is observable.
- Do not add suite-specific fixtures here; shared means shared.
