# Test plan

- Verify faults before/during/after DDL, compensation, known-state guarantees, and resumability across the supported happy-path states and canonical fixtures.
- Verify faults before/during/after DDL, compensation, known-state guarantees, and resumability under retries, interruption, concurrency, offline operation, or partial failure.
- Verify faults before/during/after DDL, compensation, known-state guarantees, and resumability preserves authorization, idempotency, integrity, observability, and actionable failure classification.

## Classification

- product regression
- blocked dependency
- harness regression
