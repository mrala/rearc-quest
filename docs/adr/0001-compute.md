# ADR-0001: Compute

Status: Proposed (provisional: gated on the `/docker` check, see Decision)

## Context
- The app is a Node/Express server on port 3000 (`src/000.js`). Each route shells out to a prebuilt Go binary in `bin/`.
- The binaries are Linux x86-64 ELF (`file bin/*`). The dev machine is darwin arm64.
- The quest requires a `node`-based container image (README task 3).
- The app is stateless and has no background workers.
- Observed in `strings bin/003`: the `/docker` check (`main.isRunningOnDocker`) references only `/.dockerenv`. [INFERENCE] Fargate runs containers on containerd, not Docker, and I believe it does not create `/.dockerenv`. Not yet verified.
- `bin/001` and `bin/002` contain `ecs` and `eks` detection functions, so ECS is a recognised environment. Whether Fargate passes `/docker` is untested.

## Decision
Run the app on **AWS ECS on Fargate**, with at least 2 tasks across 2 AZs, **provisionally**.

- Gate: deploy a throwaway Fargate task early and request `/docker`. If it does not report a Docker container, switch to **ECS on EC2** (`t3.micro` or similar x86-64 instance, ECS-optimized AMI, Docker runtime), which keeps the ALB, target group, and Terraform layout. Do not create `/.dockerenv` in the image to force a pass; that games the check. Record the finding in the README instead.
- Image: `linux/amd64`, `node:24-slim` (Node 24.22.0). Built and run locally 2026-10-20: the bundled binaries work in the slim image with no extra libraries, and `/docker` passes on a real Docker runtime. **Not `node:20`**: it reached end of life in April 2026.
- The task runs as a non-root user. `WORKDIR` is the app root, because the app calls `bin/00x` by relative path. The task definition pins `runtime_platform` to `X86_64`.
- Dependencies install with `npm ci` from the committed `package-lock.json`. `express` is bumped to `~4.22.3`, since the 4.16 line had 7 `npm audit` findings.
- `tini` is the entrypoint. Node as PID 1 ignored SIGTERM (`docker stop` took 10.4 s and ended in SIGKILL); with `tini` it stops in 0.1 s. Do not also set ECS `initProcessEnabled`.

## Alternatives considered
| Option | Why not (or when to switch) |
|---|---|
| ECS on EC2 | **Real fallback** if `/docker` fails on Fargate: Docker runtime is guaranteed. Costs more operations (AMI, instance patching, capacity). |
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
1. `/docker` fails on Fargate because `/.dockerenv` is absent.
2. `exec format error` if the image is built for the wrong platform.
3. Slim image lacks something the binaries need. (`express@4.22.3` started and served all routes on Node 26 locally; the container's Node 22 or 24 is not yet tested.)
4. `exec()` in `src/000.js` concatenates `JSON.stringify(req.headers)` into an unquoted shell command, so `$(...)` and backticks in a header value are expanded by the shell (see ADR-0009).
5. Tasks in public subnets have public IPs.

## Mitigations
1. Run the early Fargate gate before building the rest of the stack; fall back to ECS on EC2 if it fails. Record the result.
2. Build with `--platform linux/amd64`, set the task `runtime_platform` to X86_64, and smoke-test the image before pushing.
3. Test the slim image locally with all six routes; fall back to the non-slim image or another LTS.
4. Do not edit the vendor-supplied app, since the quest scores its behavior. Contain the risk with a non-root user, egress tightened after observation (ADR-0009), no task IAM role, and security groups limiting ingress to the ALB. Document it in the README as a known limitation.
5. Security group allows port 3000 only from the ALB security group (ADR-0009).
