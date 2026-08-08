# failure-injection-atomicity

Fault-injection certification for partial DDL failure, residual drift reporting, operator repair, and eventual convergence.

This repository is part of the isolated `declarative-migrations-test` certification fleet. It pins the production implementation as a Git submodule at `declarative-migrations/declarative-postgres-migrate.rs@d05a7880987ddaa271fa88b52c787390ef12b899` and exercises real database engines in GitHub Actions.

## Canonical quote atomicity lane

The Canonical lane checks out verified merge `canonical-cloud/canonical-api-server.rs@26967bed96b1b48ea846c3fd418018ea40f4b9e1` and verifies its exact schema digest, dedicated `canonical_cloud__quote` namespace, bootstrap/grants paths, PostgreSQL minimum, and DPM revision.

On PostgreSQL 17 and 18 it:

- deploys the reviewed schema with the dedicated migrator role and applies least-privilege grants;
- seeds two synthetic owner-scoped quote rows;
- derives a faulty candidate that first adds a non-null probe column and then attempts a unique index rejected by the duplicate existing values;
- verifies the generated plan orders the additive column before the failing index;
- requires a non-crashing, diagnostic failure;
- proves the probe column and index are both absent afterward, demonstrating transaction rollback;
- proves the original quote rows, forced RLS, policies, role boundaries, and owner isolation remain intact;
- immediately reapplies and verifies the production schema to prove lock release and deterministic recovery.

No production database, Cloudflare, R2, Supabase, Kubernetes, or Gemini credential is available to this repository.

## Fleet

- `.github`
- `postgres-forward-rollback`
- `cockroach-forward-rollback`
- `cross-engine-compatibility`
- `concurrent-migrator-lock`
- `failure-injection-atomicity`
- `schema-drift-detection`
- `cli-mcp-contract`

## Local contract

```bash
git submodule update --init --recursive
scripts/build-dpm.sh
```

Every behavior change must add a regression, preserve exact dependency pinning, avoid credentials in source or logs, and land through a pull request.
