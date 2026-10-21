# ADR-0005: Feature group identification

Status: Proposed

## Context
The README lists seven tasks, and five have a verification endpoint. `src/000.js` also exposes `/aws` (`bin/002`), which the README checklist does not mention.

Observed in `strings` of the supplied binaries:
- `bin/001` (`/`) and `bin/002` (`/aws`) contain cloud-provider detection for aws, ecs, eks, gcp, gke, azure, and aks, using an IMDSv2 token for EC2.
- `bin/003` (`/docker`) checks `/.dockerenv`.
- `bin/004` (`/loadbalanced`) recognises ALB, GCP, and Azure load-balancer headers.
- `bin/005` (`/tls`): criteria unknown.
- `bin/006` (`/secret_word`) reads `SECRET_WORD` from the environment. It has no HTTP client, so it does not fetch the index page itself. What it compares against is unknown.

We need a unit of delivery that is independently deployable and verifiable.

## Decision
Group work into **vertical feature groups**, one per verifiable endpoint, delivered in dependency order. A group is done only when its endpoint check passes against the deployed environment.

| # | Group | Quest tasks | Verification | Depends on |
|---|---|---|---|---|
| FG0 | Prerequisites | 1 | private repo, `.gitignore`, lockfile, scoped `quest-deployer` identity, Docker, Terraform | none |
| FG1 | Packaging | 3 (image only) | local container serves `/` and the other routes | FG0 |
| FG2 | Public cloud + index page | 2, 4 | `/` shows the secret word; `/aws` | FG1 |
| FG3 | Containerized runtime | 3 | `/docker` (**gate**: Fargate vs ECS on EC2, ADR-0001) | FG2 |
| FG4 | Secret word injection | 5 | `/secret_word` | FG2 |
| FG5 | Load balancer | 6 | `/loadbalanced` | FG2 |
| FG6 | TLS | 7 | `/tls` | FG5 |
| FG7 | Submission docs | submit list | README, ADRs, screenshot, "Given more time...", AI-use disclosure | all |

Cross-cutting concerns (cost, teardown, security) are handled in their own ADRs and apply to every group.

Reading the secret word (resolves the two-step question):
1. First run the image locally and request `/`. If the word appears, use it from the start and deploy once.
2. If `/` shows no word locally (it may need a detected cloud), deploy once without `SECRET_WORD`, read the word from the deployed `/`, then redeploy with it.
3. Whichever path applies, record it in the README.

## Alternatives considered
| Option | Why not |
|---|---|
| Group by layer (network, compute, app) | Nothing verifiable until every layer exists; late failures. |
| One big-bang deploy | Cannot localize failures. |
| Follow the README numbering | Task 5 needs the word from task 4, and 6/7 depend on infra from 2/3; strict numbering hides this. |

## Tradeoffs
- (+) Early, observable progress; each group has an objective pass/fail.
- (-) FG3 can force a compute change (Fargate to EC2) after FG2 work is done.
- (-) Possible second deploy for the secret word.

## Risks
1. `/aws` and `/tls` semantics are not fully known.
2. `/docker` may fail on Fargate (ADR-0001).
3. `/secret_word` may compare against a value we cannot see; the word on the index page may be static or per-environment, which is unverified.
4. Scope creep into the optional multi-cloud extra credit.

## Mitigations
1. Run every route in the local container and again on the first deploy; record observed output in the README.
2. Run the FG3 gate immediately after the first deploy.
3. Compare the word from `/` with the `/secret_word` result; if they disagree, record it as a finding.
4. Multi-cloud is out of scope unless FG0 to FG7 are complete.
