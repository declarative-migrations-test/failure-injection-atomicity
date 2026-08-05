# AGENTS.md

Repository: `declarative-migrations-test/failure-injection-atomicity`  
Production dependency: `declarative-migrations/declarative-postgres-migrate.rs@21eb846e356b2a5aff068b21e77903e6cca50452`

Use focused pull requests. Keep database tests deterministic and self-cleaning. Never weaken a failing convergence, rollback, drift, locking, atomicity, CLI, or MCP assertion merely to make CI green. Never commit credentials or production data. Resolve conflicts semantically with both sides and relevant history.
