## What and why

<!-- What changes, and what problem it solves. Link an issue if there is one. -->

## Verification

How this was verified. Tick only what was actually run.

- [ ] `make lint`
- [ ] `make validate`
- [ ] `make security`
- [ ] `make smoke` (requires a running stack)
- [ ] `make backup && make verify-backup` — if backup, restore or the database
      schema is touched

<!-- Paste relevant output rather than asserting it passed. -->

## Operational impact

- [ ] No change to the deployment procedure
- [ ] `DEPLOYMENT.md` updated
- [ ] `OPERATIONS.md` or a runbook updated
- [ ] `CHANGELOG.md` updated
- [ ] New or changed alert — the runbook it points at exists

## Risk

<!-- What breaks if this is wrong, and how it is rolled back. For anything
     touching the database or the filestore, say explicitly whether it is
     reversible without a restore. -->
