# AGENTS.md

Repository: `declarative-migrations-test/failure-injection-atomicity`
Current production candidate: `declarative-migrations/declarative-postgres-migrate.rs@7396f79826dc6b720771a3c6ad1905b991c7cd59`
Historical Canonical quote consumer revision: `declarative-migrations/declarative-postgres-migrate.rs@d05a7880987ddaa271fa88b52c787390ef12b899`

The historical consumer revision is immutable compatibility evidence; it does not replace the current production candidate. Keep these identities separate in manifests, verification, logs, and recovery evidence.

Use focused pull requests. Keep database tests deterministic and self-cleaning. Never weaken a failing convergence, rollback, drift, locking, atomicity, CLI, or MCP assertion merely to make CI green. Never commit credentials or production data. Resolve conflicts semantically with both sides and relevant history.

## Repository-local Git worktrees

- Create or use a Git worktree only when the human operator explicitly authorizes it for the current task. Concurrency or a dirty checkout is not permission by itself.
- Put every authorized worktree at `<repository-root>/tmp/worktrees/<name>`; from the repository root, use `./tmp/worktrees/<name>`. Never place worktrees beside repositories or organization directories.
- Keep `tmp`, `temp`, `tmp/worktrees`, and `temp/worktrees` ignored in the repository-root `.gitignore`. Do not commit files from those directories.
- Relocate or remove a worktree only when the operator explicitly requests it. Before removal, preserve and publish intended changes, verify its commit is represented on the target branch, and confirm there are no tracked, untracked, ignored-sensitive, or in-use files that must survive. Remove it with `git worktree remove <path>` without `--force`; never delete a worktree directory with `rm`.
