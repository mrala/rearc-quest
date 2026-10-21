# ADR-0002: Database

Status: Accepted (2026-10-20). No database was needed and none was built.

## Context

- `src/000.js` and `package.json` contain no datastore client. Express is the only dependency.
- The README requires no persistence. The one piece of state is `SECRET_WORD`, which is configuration injected as an env var.
- [INFERENCE] The `bin/` binaries are not known to use a database; none was observed in the source we can read. Not verified by running them.

## Decision

**Provision no database.** The service is stateless. `SECRET_WORD` is supplied as a Terraform variable and rendered into the ECS task definition as an environment variable (see ADR-0009 for how the value is stored).

## Alternatives considered

| Option | Why not |
|---|---|
| RDS (Postgres/MySQL) | Nothing reads or writes it; adds cost, subnets, credentials, and backups for no function. |
| DynamoDB | Same: no consumer. |
| Store the secret word in SSM/Secrets Manager | That is secret storage, not a database; handled in ADR-0009. |

## Tradeoffs

- (+) Zero data-layer cost, attack surface, or operational burden. Tasks are disposable and scale horizontally.
- (-) If a feature later needs persistence, it requires a new ADR plus an app change.

## Risks

1. A reviewer expects a database and reads its absence as an omission.
2. Hidden dependency: a `bin/` binary secretly needs a datastore.

## Mitigations

1. State the decision and rationale in the README.
2. The local container smoke test (all six routes) runs before any deploy. A missing dependency shows up there.

## Revisit when

The app gains state that must survive a task restart (sessions, user data, counters).
