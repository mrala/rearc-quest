# ADR-0010: Cloud portability

Status: Proposed

## Context
- The deliverable is AWS first. The README gives extra credit for working entries on more than one cloud, so a second cloud (GCP or Azure) is plausible.
- Terraform resource types are provider-specific. An abstraction over ECS, Cloud Run, and Container Apps would be leaky.
- The app and image are already cloud-neutral: a Node container with no cloud SDK use, configured through the `SECRET_WORD` env var.
- The checks are cloud-aware. `strings` on the supplied binaries shows `bin/001` and `bin/002` detect aws, gcp, and azure, and `bin/004` has separate success paths for ALB, GCP, and Azure load balancers. Portability therefore means the same contract per cloud, not the same results.
- The `/docker` check (`/.dockerenv`) fails on Fargate (confirmed 2026-10-20). It may fail on other containerd-based runtimes (Cloud Run, Kubernetes) too; untested.

## Decision
Make the **interface, image, and acceptance tests** portable. Do not abstract the cloud resources.

1. **Per-cloud root modules.** `infra/aws` is implemented now. `infra/gcp` or `infra/azure` is added only if the extra-credit step is taken.
2. **A written contract** in `infra/contract.md`. Every cloud root takes the same inputs (`image`, `image_tag`, `secret_word`, `replicas`, `tags`) and produces the same outputs (`url`, `lb_hostname`). Extract shared Terraform variable and output files only once a second cloud exists.
3. **One cloud-neutral acceptance test**, `tests/smoke.sh <BASE_URL>`, which requests all six endpoints and prints each result. It contains no cloud-specific logic.
4. **Cloud-free image.** The `Dockerfile` and `.dockerignore` contain nothing cloud-specific. The image is built once in CI or locally, tagged with the git SHA, and pushed to the target cloud's registry (or a neutral registry such as GHCR).
5. **Same verbs everywhere.** The `Makefile` takes `CLOUD` (default `aws`) and dispatches `plan`, `apply`, `smoke`, and `destroy` to `infra/$(CLOUD)`.
6. **Cert generation stays in the `tls` provider** (cloud-neutral); only the import step is per cloud.

Rough service mapping (general knowledge, not verified against current docs):

| Concern | AWS | GCP | Azure |
|---|---|---|---|
| Container runtime | ECS Fargate or EC2 | Cloud Run | Container Apps |
| Load balancer | ALB | External Application LB | Application Gateway or Front Door |
| TLS cert | ACM import | `google_compute_ssl_certificate` | Key Vault or gateway cert |
| Registry | ECR | Artifact Registry | ACR |
| Env var injection | task definition | service env | container app env |

## Alternatives considered
| Option | Why not |
|---|---|
| Kubernetes (EKS, GKE, AKS) with one Helm chart | One workload spec, but EKS costs about $73/mo for the control plane, adds a lot of moving parts, and does not avoid the `/docker` risk. |
| Pulumi, Crossplane, or OpenTofu | Same provider-specific resources. OpenTofu only changes licensing; Crossplane compositions are heavy for this scope. |
| A generic Terraform module that switches cloud via a variable | Leaky: conditionals across unrelated resource types, hard to read and test. |
| Build all clouds up front | Speculative. A contract written from one cloud is a guess. |
| No portability work | Cheapest, but makes the extra-credit step a rewrite of the Makefile and tests. |

## Tradeoffs
- (+) Adding a cloud means one new directory, not a refactor.
- (+) The shared smoke test makes cross-cloud differences visible.
- (+) Almost no extra work now: a contract doc, a script, and a Makefile variable.
- (-) Terraform is duplicated per cloud; changes to shared inputs must be made in each root.
- (-) The contract is derived from one cloud and may need revising when the second arrives.
- (-) The test cannot assert identical results, because the binaries report cloud-specific output.

## Risks
1. A cloud-specific detail leaks into the Dockerfile, `smoke.sh`, or the contract.
2. The contract is wrong for the second cloud.
3. Behaviours differ per cloud: `/docker` may fail on containerd runtimes, `/loadbalanced` may need a different Host or header pattern, and `/tls` criteria are unknown.
4. The portability work delays the AWS deliverable.

## Mitigations
1. Review the Dockerfile and `smoke.sh` for cloud references before each submission.
2. Treat the contract as provisional; revise it when the second cloud is built, and supersede this ADR if the shape changes.
3. `smoke.sh` records per-cloud output as-is, and the README documents any differences instead of masking them.
4. Limit the work now to `tests/smoke.sh`, `infra/contract.md`, and the Makefile `CLOUD` variable. Do not write a second cloud until FG0 to FG7 are complete on AWS.
