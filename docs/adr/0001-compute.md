# ADR-0001: Compute

Status: Accepted (2026-10-20). Fargate stays; `/docker` is a documented failure (see Decision).

## Context
- The app is a Node/Express server on port 3000 (`src/000.js`). Each route shells out to a prebuilt Go binary in `bin/`.
- The binaries are Linux x86-64 ELF (`file bin/*`). The dev machine is darwin arm64.
- The quest requires a `node`-based container image (README task 3).
- The app is stateless and has no background workers.
- Observed in `strings bin/003`: the `/docker` check (`main.isRunningOnDocker`) references only `/.dockerenv`. Confirmed on Fargate on 2026-10-20: the check fails there ("You dont seem to be running in a Docker container. This might be OK as many cloud container orchestration platforms do not use Docker").
- `bin/001` and `bin/002` contain `ecs` and `eks` detection functions. On Fargate `/aws` reports "Detected: ECS,AWS" and `/` returns the word, so ECS is a recognised environment.

## Decision
Run the app on **AWS ECS on Fargate**, with two tasks across 2 AZs.

- **`/docker` decision (2026-10-20):** the gate failed, so ECS on EC2 was the planned fallback. Keep Fargate instead and accept 5 of 6 routes, with `/docker` documented as a finding: the check only tests for `/.dockerenv`, which containerd-based runtimes do not create. Reason: the container, ALB, TLS, secret-word and AWS checks are all demonstrated, and ECS on EC2 would add instances, an Auto Scaling group and an instance role to manage for one route. Do not create `/.dockerenv` in the image to force a pass; that games the check. A real Docker runtime (ECS on EC2) passes `/docker` locally in the same image, which is the evidence that the image itself is right.
- Image: `linux/amd64`, `node:24-slim` (Node 24.22.0) plus `ca-certificates` and `tini`. The bundled binaries are static and need no other libraries, but `bin/001` verifies `https://www.rearc.io` against the system CA store, which the slim image lacks (found on the first Fargate deploy). **Not `node:20`**: it reached end of life in April 2026.
- The task runs as a non-root user. `WORKDIR` is the app root, because the app calls `bin/00x` by relative path. The task definition pins `runtime_platform` to `X86_64`.
- Dependencies install with `npm ci` from the committed `package-lock.json`. `express` is bumped to `~4.22.3`, since the 4.16 line had 7 `npm audit` findings.
- `tini` is the entrypoint. Node as PID 1 ignored SIGTERM (`docker stop` took 10.4 s and ended in SIGKILL); with `tini` it stops in 0.1 s. Do not also set ECS `initProcessEnabled`.

## Alternatives considered
| Option | Why not (or when to switch) |
|---|---|
| ECS on EC2 | Would pass `/docker` (Docker runtime), but adds AMI, instance patching, an Auto Scaling group and an instance role for one route. Not chosen on 2026-10-20; the first item in "Given more time" if all six routes matter. |
| EC2 + plain Docker | Patching, AMIs, SSH to manage; no benefit over ECS on EC2 for one container. |
| EKS | Control-plane cost (~$73/mo) and complexity far beyond one container. |
| App Runner | Simplest, but it hides the load balancer and TLS config the quest asks us to demonstrate. |
| Lambda | The app is a long-running HTTP server that execs binaries; poor fit. |
| Fargate on ARM64 (Graviton) | Cheaper, but the bundled binaries are x86-64 only. |

## Tradeoffs
- (+) Fargate: no hosts to patch, task-level isolation, native ALB integration.
- (+) Min 2 tasks makes `/loadbalanced` show real balancing.
- (-) Fargate may fail the `/docker` check (unverified), which could force the EC2 variant.
- (-) Fargate costs more per vCPU-hour than EC2.
- (-) x86-64 forces an emulated or remote build on Apple Silicon.

## Risks
1. **Confirmed 2026-10-20:** `/docker` fails on Fargate because `/.dockerenv` is absent (the check is `/.dockerenv` only). Fargate passes the other five routes.
2. `exec format error` if the image is built for the wrong platform.
3. Slim image lacks something the binaries need. **Happened:** `node:24-slim` has no CA certificates, so `bin/001` could not verify `https://www.rearc.io` and `/` panicked on Fargate. Fixed by installing `ca-certificates`.
4. `exec()` in `src/000.js` concatenates `JSON.stringify(req.headers)` into an unquoted shell command, so `$(...)` and backticks in a header value are expanded by the shell (see ADR-0009).
5. Tasks in public subnets have public IPs.

## Mitigations
1. The Fargate gate ran on 2026-10-20 and failed `/docker`. Decision: keep Fargate and document 5 of 6 (see Decision). Revisit if a six-of-six result is required.
2. Build with `--platform linux/amd64`, set the task `runtime_platform` to X86_64, and smoke-test the image before pushing.
3. Test the slim image locally with all six routes; fall back to the non-slim image or another LTS.
4. Do not edit the vendor-supplied app, since the quest scores its behavior. Contain the risk with a non-root user, egress tightened after observation (ADR-0009), no task IAM role, and security groups limiting ingress to the ALB. Document it in the README as a known limitation.
5. Security group allows port 3000 only from the ALB security group (ADR-0009).
