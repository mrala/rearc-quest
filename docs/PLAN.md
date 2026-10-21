# Quest Plan: AWS, Terraform, ECS (Fargate, provisional)

Status: Proposed. Decisions are recorded in `docs/adr/0001` to `0010`. This revision incorporates a self-review of the first draft (see "Corrections log"), a portability decision (ADR-0010), and a second round of web-checked corrections.

## Findings

Verified (observed in this repo or with local commands):
- The app is Express on port 3000 (`src/000.js`). Each route shells out to a prebuilt Go binary: `/`→`bin/001`, `/aws`→`002`, `/docker`→`003`, `/loadbalanced`→`004`, `/tls`→`005`, `/secret_word`→`006`.
- The binaries are Linux x86-64 ELF. The dev machine is darwin arm64, so they can't run locally. The image must be built for `linux/amd64`.
- Local tooling (verified 2026-10-20): `docker` 29.8.2 (OrbStack, with working `linux/amd64` emulation), `terraform` 1.16.6 (asdf), `aws` 2.38.2, `node`. `bin/003` runs under amd64 emulation and prints the Docker success message.
- **AWS identity:** the default profile is the **root user** via `aws login` (region `us-east-1`, account has root MFA on, 4 existing IAM users and 5 CDK roles that must not be touched). Root is not used for deploys. A scoped IAM user `quest-deployer` and customer-managed policy `QuestDeployer` were created from `infra/aws/bootstrap/` (see ADR-0009). **Pending: console password, MFA, and `aws login --profile quest-deployer` (manual).**
- `origin` is now the private `https://github.com/mrala/rearc-quest.git` (created, empty, nothing pushed). The vendor repo is `upstream`.
- `.gitignore` and `package-lock.json` now exist. `express` was bumped from `~4.16.3` to `~4.22.3` (`npm audit`: 0 vulnerabilities, down from 7). Locally, on Node 26, the server starts and answers all six routes plus a 404. The bundled binaries cannot run on macOS (`cannot execute binary file`), so only the Express layer was tested.
- **Header command injection confirmed locally:** a request header `X-Probe: $(touch /tmp/quest-inj)` created the file. The marker was removed. Do not repeat this against the public deployment.
- The app has no database dependency in `package.json` or `src/000.js`. `SECRET_WORD` is an env var.
- `strings` on the binaries shows:
  - `003` (`/docker`) checks `/.dockerenv`.
  - `004` (`/loadbalanced`) recognises ALB headers (`X-Amzn-Trace-Id`, `X-Forwarded-For`, `elb.amazonaws.com`) and GCP/Azure load-balancer cases.
  - `001`/`002` detect aws, ecs, eks, gcp, gke, azure, aks (IMDSv2 for EC2).
  - `006` reads `SECRET_WORD` and has no HTTP client.
  - `005` (`/tls`) criteria are not visible.
- Checked on the web (2026-10-20): Node 20 is EOL and v22 and v24 are LTS (nodejs.org). The ALB ($0.0225/hr) and Fargate x86 rates match the AWS pricing pages. The Terraform AWS provider supports `aws login` credentials from v6.23.0; the S3 backend did not at the time (hashicorp/terraform-provider-aws#45316).

Inferred, not verified:
- [INFERENCE] Fargate (containerd) does not create `/.dockerenv`, so `/docker` may fail there. Gate on an early test.
- [INFERENCE] `/loadbalanced` may match Host against `elb.amazonaws.com`, so a custom domain could break it.
- [INFERENCE] `/tls` may read `X-Forwarded-Proto`.
- [INFERENCE] Cost is about $1.5 to $2/day (ADR-0008); check the pricing page.
- [INFERENCE] `bin/001` cloud detection (IMDSv2) may block on Fargate, making `/` slow and a poor health-check path.
- [INFERENCE] Restricting task egress may break the binaries, which embed HTTP clients (ADR-0009).

## Steps

0. **Prerequisites (FG0)**
   - Create a private repo and repoint `origin`.
   - Add `.gitignore` (`node_modules/`, `.terraform/`, `*.tfstate*`, `*.tfvars`).
   - Run `npm install` and commit `package-lock.json`.
   - Bootstrap the scoped deployer (done, `infra/aws/bootstrap/bootstrap.sh`); then set a console password and MFA for `quest-deployer` and run `aws login --profile quest-deployer --region us-east-1`. Confirm `aws sts get-caller-identity --profile quest-deployer` shows the IAM user, not root.
   - Docker and Terraform are installed (verified).
   - Pin the Terraform AWS provider to `>= 6.23.0` and use local state (ADR-0004).
   - Keep the vendor `README.md`; write the submission docs in `SOLUTION.md` and link it from the top of `README.md`.
1. **Dockerfile (FG1)**
   - `FROM --platform=linux/amd64 node:24-slim` (or `22-slim`). **Not `node:20`** (EOL April 2026).
   - `WORKDIR` is the app root, since the app execs `bin/00x` by relative path.
   - Copy `package*.json`, run `npm ci --omit=dev`, then copy `src/` and `bin/`.
   - Run as a non-root user and `EXPOSE 3000`.
   - Add a `.dockerignore` for `.git`, `node_modules`, and `docs/`.
   - Run the container locally and request all six routes. If the binaries fail in the slim image, use the non-slim one.
   - Keep the `Dockerfile` and `.dockerignore` cloud-free (ADR-0010). The `Dockerfile` lives at the repo root so the build context includes `src/` and `bin/`.
2. **Secret word (FG2, FG4)**
   - Request `/` locally. If the word shows, use it. Otherwise deploy once without it, read `/` on the deployment, then redeploy with `SECRET_WORD` set (ADR-0005).
   - Pass it as a `sensitive` Terraform variable. Do not hardcode it.
3. **Early Fargate gate (FG3)**
   - Deploy a throwaway Fargate task and request `/docker`.
   - If it fails, switch to ECS on EC2 (ADR-0001). Do not create `/.dockerenv` in the image to force a pass. Record the finding.
4. **Terraform (`infra/aws/`)**
   - Networking: VPC, 2 public subnets across 2 AZs, internet gateway, route tables. No NAT.
   - ECR repository and a push step.
   - ECS cluster, task definition (`SECRET_WORD`, CloudWatch logs, `runtime_platform` X86_64), service, execution role.
   - Security groups: the ALB accepts 80 and 443 from the internet. Tasks accept 3000 only from the ALB. Start with open task egress, observe, then tighten (ADR-0009).
   - ALB with a target group on port 3000. Health-check path starts as `/` and is changed to the fastest route after measuring (ADR-0003).
   - TLS: a self-signed RSA 2048 cert (placeholder CN, wildcard SAN) from the `tls` provider imported into ACM. HTTPS:443 listener, and HTTP:80 redirects to HTTPS.
   - At least 2 tasks so `/loadbalanced` shows real balancing.
   - AWS Budget, tags (`project`, `ttl`), 7-day log retention, ECR lifecycle policy.
   - Output the ALB DNS name.
   - Run `terraform validate` and `plan`. Several resource arguments and the TLS policy name come from memory.
   - Write `infra/contract.md` (ADR-0010): the inputs (`image`, `image_tag`, `secret_word`, `replicas`, `tags`) and outputs (`url`, `lb_hostname`) every cloud root must provide. Treat it as provisional until a second cloud exists.
   - Add a `Makefile` with a `CLOUD` variable (default `aws`) dispatching `plan`, `apply`, `smoke`, and `destroy` to `infra/$(CLOUD)`.
   - Write `tests/smoke.sh <BASE_URL>`: requests all six endpoints and prints each result, with no cloud-specific logic.
5. **Verify** through the ALB DNS name, using `curl -k`:
   - Run `tests/smoke.sh https://<alb-dns>` for all six endpoints; the manual checks below cover what it cannot.
   - Measure `curl -w '%{time_total}'` per route and pick the health-check path from the result.
   - `/` shows the secret word; `/aws` output is recorded.
   - `/docker`, `/secret_word`, `/loadbalanced` and `/tls` each report success. Record any that don't, with their output.
   - Request the task public IP directly and expect a timeout.
   - The injection was already confirmed locally; do not probe the public deployment.
   - Screenshot the index page and each check before teardown.
6. **Docs (FG7)**
   - `SOLUTION.md` covering architecture, deploy and teardown steps, observed findings, and the AI-usage disclosure: prompts, what helped, what the AI got wrong (see the corrections log), and what was verified. Be able to explain every decision in the interview; the ADRs are AI-drafted and contain judgment calls that need your own review.
   - The "Given more time, I would improve..." answer. Candidates: patching the `exec` injection with `execFile`, a real domain with ACM (after checking the Host question), private subnets with NAT or VPC endpoints, CI/CD with OIDC, Secrets Manager, WAF, autoscaling, remote state with locking, image scanning and pinned digests.
7. **Teardown**: `make destroy`, then check for leftover tagged resources (ADR-0007).
8. **Optional extra credit**: GCP (Cloud Run behind a load balancer) or Azure, only after FG0 to FG7 are complete on AWS. Add `infra/gcp/` (or `infra/azure/`) implementing `infra/contract.md`, reuse `tests/smoke.sh`, and record any per-cloud differences in the README (ADR-0010).

## Feature groups (ADR-0005)

| # | Group | Verification | Depends on |
|---|---|---|---|
| FG0 | Prerequisites | private repo, `.gitignore`, lockfile, scoped `quest-deployer` identity, Docker, Terraform | none |
| FG1 | Packaging | local container serves all routes | FG0 |
| FG2 | Public cloud + index page | `/` shows the secret word; `/aws` | FG1 |
| FG3 | Containerized runtime | `/docker` (gate: Fargate vs ECS on EC2) | FG2 |
| FG4 | Secret word injection | `/secret_word` | FG2 |
| FG5 | Load balancer | `/loadbalanced` | FG2 |
| FG6 | TLS | `/tls` | FG5 |
| FG7 | Submission docs | README, ADRs, screenshot, "Given more time..." | all |

## Repo layout (ADR-0010)

```
Dockerfile, .dockerignore   cloud-free
src/, bin/, package*.json   vendor app
SOLUTION.md                 submission docs; README.md is the vendor text
infra/
  contract.md               inputs/outputs every cloud must implement
  aws/                      implemented now
  gcp/                      optional, later
tests/smoke.sh              takes BASE_URL, checks all six endpoints
Makefile                    CLOUD=aws by default
docs/                       PLAN.md, adr/
```

## ADR index

| ADR | Topic |
|---|---|
| 0001 | Compute (Fargate provisional, ECS on EC2 fallback) |
| 0002 | Database (none) |
| 0003 | Networking |
| 0004 | CI/CD |
| 0005 | Feature group identification |
| 0006 | Database seeding / replication (none) |
| 0007 | Teardown |
| 0008 | Cost controls |
| 0009 | Security |
| 0010 | Cloud portability (contract, smoke test, per-cloud roots) |

## Corrections log (self-review of the first draft)

| Original claim | Correction | ADR / section |
|---|---|---|
| `aws` is configured | No active session; `aws login` required | FG0, ADR-0004 |
| `npm ci` in the Dockerfile | No lockfile exists; `npm install` first and commit it | ADR-0001, ADR-0004 |
| `node:20-slim` | Node 20 is EOL (confirmed on nodejs.org); use 22 or 24 (both LTS) | ADR-0001 |
| Injection via a `'` in a header | Vectors are `$(...)` and backticks inside the shell's double quotes | ADR-0009 |
| Cost "a few dollars per day" | About $1.5 to $2/day by estimate; ALB and Fargate rates confirmed on AWS pricing pages, IPv4 rate still from memory | ADR-0008 |
| The secret word differs per environment | Unverified; `bin/006` only reads the env var | ADR-0005, ADR-0006 |
| Task 1 "mostly done" | `origin` is upstream; a private repo is needed | ADR-0004 |
| Fargate chosen without caveat | `/docker` may fail on Fargate (`/.dockerenv`); early gate and EC2 fallback added | ADR-0001, ADR-0005 |
| Real domain as a plain improvement | May break `/loadbalanced` Host match; test first | ADR-0003 |
| `/tls` likely checks HTTPS headers | Criteria unknown | ADR-0003 |
| Two-deploy flow vs local-run flow (docs disagreed) | Unified decision flow in ADR-0005 | ADR-0005 |
| Region taken from the CLI config | No region is configured; choose explicitly | ADR-0004, FG0 |
| `aws login` assumed to work with Terraform | Provider needs `>= 6.23.0`; the S3 backend did not accept it, so use local state | ADR-0004 |
| Deploy as the root user from `aws login` | Root is unrestricted; created a region- and prefix-scoped `quest-deployer` IAM user | ADR-0009 |
| ALB assumed to be covered by the 750-hour free tier | Accounts since July 2025 get credits and a 6-month free plan; check the account | ADR-0008 |
| Task egress limited to 443 | Binaries embed HTTP clients; start open, observe, then tighten | ADR-0009 |
| `/` as the health-check path | `bin/001` cloud detection may block on Fargate; measure and choose | ADR-0003 |
| "README covering..." with no file named | The vendor `README.md` stays; use `SOLUTION.md` | FG7 |
| Imported cert key type unspecified | RSA 2048 | ADR-0003 |
| Teardown ignored the EC2 fallback and tag-API gaps | Added EC2 resources and a manual checklist | ADR-0007 |

## Open decisions

- **Cloud and region:** AWS, `us-east-1` (set in the CLI config).
- **Deployer credentials:** you must set the `quest-deployer` console password and MFA, then `aws login` as that user. The simulator proves the policy's allow/deny rules, but not that Terraform has every permission it needs. Expect to widen the policy if `plan` or `apply` hits AccessDenied.
- **Build location:** local `docker buildx --platform linux/amd64` through OrbStack emulation (verified working). CodeBuild is only a fallback if local builds prove too slow.
- **Apply:** I'll write and validate the IaC first and ask before the first `terraform apply`. Expected cost is about $1.5 to $2/day (ALB, Fargate, IPv4).
- **Second cloud:** none is planned beyond the contract in ADR-0010. GCP or Azure is extra credit, taken only after the AWS deliverable is complete.
- **Account type:** check whether the account is on the credits-based free plan and whether it restricts any service we need (ADR-0008).
