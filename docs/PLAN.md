# Quest Plan: AWS, Terraform, ECS Fargate

Status: Executed on AWS on 2026-10-20 (5 of 6 checks pass; `/docker` fails on Fargate and is accepted). Remaining: teardown by 2026-10-27. Decisions are recorded in `docs/adr/0001` to `0010`, whose statuses reflect what was built and tested. This document began as a plan; it now also holds the findings and a log of what had to be corrected (see "Corrections log").

## Findings

Verified (observed in this repo or with local commands):
- The app is Express on port 3000 (`src/000.js`). Each route shells out to a prebuilt Go binary: `/`→`bin/001`, `/aws`→`002`, `/docker`→`003`, `/loadbalanced`→`004`, `/tls`→`005`, `/secret_word`→`006`.
- The binaries are Linux x86-64 ELF. The dev machine is darwin arm64, so they can't run locally. The image must be built for `linux/amd64`.
- Local tooling (verified 2026-10-20): `docker` 29.8.2 (OrbStack, with working `linux/amd64` emulation), `terraform` 1.16.6 (asdf), `aws` 2.38.2, `node`. `bin/003` runs under amd64 emulation and prints the Docker success message.
- **AWS identity:** the default profile is the **root user** via `aws login` (region `us-east-1`, account has root MFA on, 4 existing IAM users and 5 CDK roles that must not be touched). Root is not used for deploys. The scoped IAM user `quest-deployer` and customer-managed policy `QuestDeployer` were created from `infra/aws/bootstrap/` (see ADR-0009), and `aws login --profile quest-deployer` works and reports `user/quest-deployer`. MFA on that user is unconfirmed.
- `origin` is the private `https://github.com/mrala/rearc-quest.git` and all commits are pushed (2026-10-20). The vendor repo is `upstream`.
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

Verified in the local container (`quest:local`, linux/amd64, 2026-10-20):
- The image builds (Node 24.22.0, about 99 MB), runs as uid 1000, and `/docker` reports "running in a Docker container".
- `/` and `/aws` print "You don't seem to be running in AWS or GCP or Azure" and take about 25 s. `/loadbalanced` takes about 5 s. `/docker`, `/tls` and `/secret_word` take under 100 ms. **The secret word is not shown outside a cloud**, so it must be read from the deployed index page (ADR-0005).
- `/tls` passes when the request carries `X-Forwarded-Proto: https`; no real TLS was involved, so this shows what the check reads.
- `/loadbalanced` passes with `X-Amzn-Trace-Id`, `X-Forwarded-For`, `X-Forwarded-Proto` and `X-Forwarded-Port` and a `localhost` Host header, so a Host match is not required. `X-Forwarded-For` alone fails. I did not isolate which of the other headers is required.
- `/secret_word` echoes any `SECRET_WORD` value ("Secret word is: <value>"); it does not validate the value locally.
- All six routes give the same results under `--read-only`, `--cap-drop ALL` and `--security-opt no-new-privileges`.
- Node as PID 1 ignored SIGTERM: `docker stop` took 10.4 s (SIGKILL, exit 137). With `tini` as PID 1 it takes 0.1 s (exit 143), so `tini` is in the image.
- Forged headers show only what the checks look for. Only a real ALB proves them.

Verified on the first Fargate deploy (2026-10-20, 31 resources; the ALB hostname changes on every rebuild; `ttl` tag 2026-10-27):
- The apply ran with no AccessDenied and took about 3 minutes (the ALB takes about 2.5 min). A new image or a `SECRET_WORD` change rolls the service in about 3 to 4 minutes.
- Both tasks pass the `/tls` health check with a read-only root filesystem and all capabilities dropped.
- `/` panicked at first: `bin/001` fetches the secret word from `https://www.rearc.io` and failed with `x509: certificate signed by unknown authority`, because `node:24-slim` ships no CA bundle. Fixed by installing `ca-certificates` (commit `9f28ffd`). Locally `/` never reaches that call, so the local smoke test could not catch it.
- After the fix `/` returns the secret word in 0.5 to 1.8 s and `/aws` says "You are running in AWS, Detected: ECS,AWS" in about 0.15 s. Cloud detection works on Fargate and is fast there; the 25 s was local only. Both tasks return the same word.
- `/loadbalanced` and `/tls` pass through the real ALB. After setting `SECRET_WORD`, `/secret_word` prints the same word as the index page.
- **`/docker` fails on Fargate**: "You dont seem to be running in a Docker container. This might be OK as many cloud container orchestration platforms do not use Docker". The `/.dockerenv` inference is confirmed. 5 of 6 routes pass.
- HTTP returns 301 to HTTPS. Both task public IPs refuse direct connections on port 3000. The listener negotiates TLS 1.3 with `ELBSecurityPolicy-TLS13-1-2-2021-06`.

Inferred, not verified:
- [INFERENCE] Cost is about $1.5 to $2/day (ADR-0008); check the pricing page.
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
   - `FROM --platform=linux/amd64 node:24-slim`, built and tested (Node 24.22.0, no extra libraries needed). **Not `node:20`** (EOL April 2026).
   - `WORKDIR` is the app root, since the app execs `bin/00x` by relative path.
   - Copy `package*.json`, run `npm ci --omit=dev`, then copy `src/` and `bin/`.
   - Run as a non-root user and `EXPOSE 3000`.
   - `tini` is the entrypoint so SIGTERM stops the app promptly (see Findings).
   - Add a `.dockerignore` for `.git`, `node_modules`, and `docs/`.
   - Run the container locally and request all six routes. If the binaries fail in the slim image, use the non-slim one.
   - Keep the `Dockerfile` and `.dockerignore` cloud-free (ADR-0010). The `Dockerfile` lives at the repo root so the build context includes `src/` and `bin/`.
2. **Secret word (FG2, FG4)**
   - Verified locally: `/` shows no word outside a cloud. Deploy once without `SECRET_WORD`, read the word from `/` on the deployment, then redeploy with it set (ADR-0005).
   - Pass it as a `sensitive` Terraform variable. Do not hardcode it.
3. **Fargate gate (FG3), done**
   - **Result (2026-10-20): `/docker` fails on Fargate.** Decision: keep Fargate and document 5 of 6 (ADR-0001). Do not create `/.dockerenv` in the image to force a pass.
4. **Terraform (`infra/aws/`)**
   - Networking: VPC, 2 public subnets across 2 AZs, internet gateway, route tables. No NAT.
   - ECR repository and a push step.
   - ECS cluster, task definition (`SECRET_WORD`, CloudWatch logs, `runtime_platform` X86_64), service, execution role.
   - Security groups: the ALB accepts 80 and 443 from the internet. Tasks accept 3000 only from the ALB. Start with open task egress, observe, then tighten (ADR-0009).
   - ALB with a target group on port 3000. The health-check path is `/tls`, a fast route (`/` takes about 25 s locally); re-measure on AWS (ADR-0003).
   - TLS: a self-signed RSA 2048 cert (placeholder CN, wildcard SAN) from the `tls` provider imported into ACM. HTTPS:443 listener, and HTTP:80 redirects to HTTPS.
   - At least 2 tasks so `/loadbalanced` shows real balancing.
   - AWS Budget (only when `budget_email` is set; it covers the whole account because tag filtering needs the cost allocation tag activated), tags (`project`, `managed_by`, optional `ttl`), 7-day log retention, ECR lifecycle policy (keep 5 images).
   - Output the ALB DNS name.
   - **Done and applied 2026-10-20:** the module (`infra/aws/*.tf`, 31 resources), `infra/aws/Makefile` and `infra/contract.md`. Before the apply, `terraform validate` passed on aws provider 6.69.1 and tls 4.4.1 (lock file committed), `terraform plan` as `quest-deployer` showed the expected resources, the TLS policy `ELBSecurityPolicy-TLS13-1-2-2021-06` existed, and 39 IAM-simulator checks covering every non-wildcard action Terraform needs were all allowed. The apply then ran with no AccessDenied (see Findings).
   - `make apply` has to create the ECR repository first (`-target`), push the image, then apply the rest, because the service starts tasks as soon as it exists. The Makefile refuses to run as root and prints the identity and region first.
   - `make verify-clean` queries the tagging API and each service, excludes the deployer's own user and policy, and exits 1 if anything is left. Tested clean, and against a stubbed leftover.
   - **Done:** `Makefile` with `CLOUD` (default `aws`). `build`, `run-local`, `smoke-local` and `smoke` work; `plan`, `apply`, `push`, `destroy` and `verify-clean` delegate to `infra/$(CLOUD)/Makefile`. `apply` and `push` build first. Images are tagged with the git SHA (`-dirty` if uncommitted), never `latest`.
   - **Done:** `tests/smoke.sh [-k] [-H hdr]... [-s route]... [-t secs] BASE_URL` checks all six routes in parallel, prints one row per route, and exits non-zero on any failure. `EXPECT_SECRET_WORD` also checks `/secret_word`. The success text of `/` and `/aws` is unknown, so they pass when they return anything other than the "not in a cloud" text.
   - `make smoke-local` runs the hardened image with forged ALB headers and skips `/` and `/aws` (they need a cloud): 4 passed, 0 failed, 2 skipped, about 8 s. Tested failure paths: missing headers, wrong expected word, dead port, bad arguments.
5. **Verify** through the ALB DNS name, using `curl -k`:
   - Run `make smoke` (or `tests/smoke.sh -k https://<alb-dns>`) for all six endpoints; the manual checks below cover what it cannot.
   - Health-check path: use one of the fast routes (`/docker`, `/tls`, `/secret_word`; about 50 ms locally), not `/` (25 s) or `/loadbalanced` (5 s). Re-measure on AWS.
   - `/` shows the secret word; `/aws` output is recorded.
   - `/docker`, `/secret_word`, `/loadbalanced` and `/tls` each report success. Record any that don't, with their output.
   - Request the task public IP directly and expect a timeout.
   - The injection was already confirmed locally; do not probe the public deployment.
   - **Done 2026-10-20:** `docs/screenshots/01-index.png` to `06-tls.png`, one per route, taken through the ALB with headless Chromium (certificate errors ignored, since the cert is self-signed). Each image has a caption strip added above the page showing the URL, HTTP status and UTC capture time, because headless screenshots have no address bar; the page content below it is unmodified. `03-docker.png` is the accepted `/docker` failure. Retake them if the stack is rebuilt, because the ALB hostname changes.
6. **Docs (FG7)**
   - **Done 2026-10-20:** `SOLUTION.md`, linked from the top of `README.md`, covering architecture, deploy and teardown steps, findings, cost, the AI-usage disclosure (prompts, what helped, what the AI got wrong, what to verify), and "Given more time". Teardown has not been run yet. Be able to explain every decision in the interview; the ADRs are AI-drafted and contain judgment calls that need your own review.
   - The "Given more time, I would improve..." answer. Candidates: patching the `exec` injection with `execFile`, a real domain with ACM (after checking the Host question), private subnets with NAT or VPC endpoints, CI/CD with OIDC, Secrets Manager, WAF, autoscaling, remote state with locking, image scanning and pinned digests.
7. **Teardown**: `make destroy`, then check for leftover tagged resources (ADR-0007).
8. **Optional extra credit**: GCP (Cloud Run behind a load balancer) or Azure, only after FG0 to FG7 are complete on AWS. Add `infra/gcp/` (or `infra/azure/`) implementing `infra/contract.md`, reuse `tests/smoke.sh`, and record any per-cloud differences in the README (ADR-0010).

## Feature groups (ADR-0005)

| # | Group | Verification | Depends on |
|---|---|---|---|
| FG0 | Prerequisites | private repo, `.gitignore`, lockfile, scoped `quest-deployer` identity, Docker, Terraform | none |
| FG1 | Packaging | local container serves all routes (**done 2026-10-20**) | FG0 |
| FG2 | Public cloud + index page | `/` shows the secret word; `/aws` | FG1 |
| FG3 | Containerized runtime | `/docker`: fails on Fargate, accepted (ADR-0001) | FG2 |
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
tests/smoke.sh              BASE_URL in, six checks out (done)
Makefile                    CLOUD=aws by default (done)
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

## Corrections log (self-review and deploy findings)

| Original claim | Correction | ADR / section |
|---|---|---|
| `aws` is configured | No active session; `aws login` required | FG0, ADR-0004 |
| `npm ci` in the Dockerfile | No lockfile exists; `npm install` first and commit it | ADR-0001, ADR-0004 |
| `node:20-slim` | Node 20 is EOL (confirmed on nodejs.org); use 22 or 24 (both LTS) | ADR-0001 |
| Injection via a `'` in a header | Vectors are `$(...)` and backticks inside the shell's double quotes | ADR-0009 |
| Cost "a few dollars per day" | About $1.5 to $2/day by estimate; ALB and Fargate rates confirmed on AWS pricing pages, IPv4 rate still from memory | ADR-0008 |
| The secret word differs per environment | Unverified; `bin/006` only reads the env var | ADR-0005, ADR-0006 |
| Task 1 "mostly done" | `origin` is upstream; a private repo is needed | ADR-0004 |
| Fargate chosen without caveat | `/docker` fails on Fargate (`/.dockerenv`); kept Fargate and documented it | ADR-0001, ADR-0005 |
| Real domain as a plain improvement | A Host match was not needed locally with ALB-style headers; still test on AWS | ADR-0003 |
| `/tls` likely checks HTTPS headers | Reads `X-Forwarded-Proto: https` (verified with a forged header) | ADR-0003 |
| Two-deploy flow vs local-run flow (docs disagreed) | Unified decision flow in ADR-0005 | ADR-0005 |
| Region taken from the CLI config | No region is configured; choose explicitly | ADR-0004, FG0 |
| `aws login` assumed to work with Terraform | Provider needs `>= 6.23.0`; the S3 backend did not accept it, so use local state | ADR-0004 |
| Deploy as the root user from `aws login` | Root is unrestricted; created a region- and prefix-scoped `quest-deployer` IAM user | ADR-0009 |
| ALB assumed to be covered by the 750-hour free tier | Accounts since July 2025 get credits and a 6-month free plan; check the account | ADR-0008 |
| Task egress limited to 443 | Binaries embed HTTP clients; start open, observe, then tighten | ADR-0009 |
| `/` as the health-check path | Measured about 25 s locally; use a fast route instead | ADR-0003 |
| "README covering..." with no file named | The vendor `README.md` stays; use `SOLUTION.md` | FG7 |
| Imported cert key type unspecified | RSA 2048 | ADR-0003 |
| Teardown ignored the EC2 fallback and tag-API gaps | Added EC2 resources and a manual checklist | ADR-0007 |
| Dockerfile ran `node` as PID 1 | SIGTERM was ignored (10.4 s stop, exit 137); added `tini` | Dockerfile |
| Two possible secret-word flows | Verified `/` shows no word locally, so deploy once, read it, redeploy | ADR-0005 |
| Assumed `node:slim` ships CA certificates | It does not; `/` panicked on the first deploy. Added `ca-certificates` | Dockerfile |
| Local smoke test treated as enough for `/` | `/` only reaches the TLS fetch inside a cloud; only a real deploy catches it | tests/smoke.sh |
| `/docker` on Fargate "may fail" | Fails as predicted: Fargate has no `/.dockerenv` | ADR-0001 |
| Cloud detection assumed possibly slow on Fargate | Fast there (about 0.15 to 1.8 s); the 25 s was local only | ADR-0003 |

## Open decisions

- **Cloud and region:** AWS, `us-east-1` (set in the CLI config).
- **Deployer credentials:** done. `aws login --profile quest-deployer` works and the first `plan` and `apply` needed no policy change. MFA on that user is unconfirmed.
- **Build location:** local `docker buildx --platform linux/amd64` through OrbStack emulation (verified working). CodeBuild is only a fallback if local builds prove too slow.
- **Apply:** done 2026-10-20 (31 resources), billed until `make destroy`. Expected cost about $1.5 to $2/day (ALB, Fargate, IPv4); the budget alert goes to the address in `terraform.tfvars`.
- **`/docker`:** decided 2026-10-20: keep Fargate, document 5 of 6 (ADR-0001).
- **Second cloud:** none is planned beyond the contract in ADR-0010. GCP or Azure is extra credit, taken only after the AWS deliverable is complete.
- **Account type:** check whether the account is on the credits-based free plan and whether it restricts any service we need (ADR-0008).
