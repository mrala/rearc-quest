# ADR-0006: Database seeding / replication

Status: Proposed (depends on ADR-0002)

## Context
ADR-0002 decides there is no database. Seeding and replication therefore have no data to operate on. The only per-environment value is `SECRET_WORD`, which is configuration, and the service's availability comes from running multiple stateless tasks behind the ALB.

Whether the secret word is static or varies per deployment is **unverified**. `bin/006` only reads `SECRET_WORD` from the environment and has no HTTP client, so it does not fetch the index page. The README says to take the word from the index page.

## Decision
- **Seeding:** none. The "seed" for an environment is the Terraform variable `secret_word`, applied through the task definition. No migration or seed job exists.
- **Replication:** none for data. Redundancy comes from running **at least 2 tasks across 2 AZs** (ADR-0001, ADR-0003), not from replicating state.
- **Reproducibility** comes from Terraform plus a SHA-tagged image, so a destroyed environment is recreated by `make apply`.

## Alternatives considered
| Option | Why not |
|---|---|
| Seed job (ECS one-off task) with fixture data | No schema or consumer. |
| Multi-AZ RDS / Aurora replicas | No database (ADR-0002). |
| Cross-region replication / DR | Demo scope; a rebuild from IaC is the recovery path. |

## Tradeoffs
- (+) Nothing to migrate, back up, or fail over.
- (-) No state means no data-level recovery story, which is acceptable only while nothing is stored.

## Risks
1. A rebuilt environment may show a different word on `/`, so the stored value could go stale. Unverified.
2. If persistence is added later, this ADR would be silently wrong.

## Mitigations
1. Keep the word in a gitignored tfvars file. After any rebuild, re-read `/` and compare with the stored value (ADR-0005 flow).
2. ADR-0002 "Revisit when" triggers a rewrite of this ADR. Supersede it, do not patch it in place, when a datastore is introduced: define the migration tool, seed fixtures, and replica or Multi-AZ policy then.
