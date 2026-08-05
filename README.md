# Failed-step atomicity and recovery certification

This repository injects a late migration failure against live PostgreSQL and CockroachDB instances, inspects the resulting catalog, proves residual drift remains visible, repairs the conflicting data, and then proves eventual convergence.

Production is pinned to `declarative-migrations/declarative-postgres-migrate.rs@21eb846e356b2a5aff068b21e77903e6cca50452`.

The test never assumes that a failed migration restored the original catalog without independently querying the database.
