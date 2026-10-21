# ADR-0003: Networking

Status: Proposed

## Context
Requirements: a load balancer in front of the app (task 6), HTTPS with locally generated certs allowed (task 7), a load-balanced check at `/loadbalanced`, and a TLS check at `/tls`.

Observed in `strings` of the supplied binaries:
- `bin/004` contains `elb.amazonaws.com`, `X-Amzn-Trace-Id`, `X-Forwarded-For`, and separate success messages for GCP and Azure load balancers. An AWS ALB is therefore a recognised case.
- [INFERENCE] `bin/004` may match the Host header against `elb.amazonaws.com`. If so, a custom domain could make `/loadbalanced` fail. Untested.
- `bin/005` (`/tls`) shows only the strings `https` and `false`. Its criteria are **unknown**. [INFERENCE] It may read `X-Forwarded-Proto`; not verified.

## Decision
- New VPC with **2 public subnets in 2 AZs**, an internet gateway, and no NAT gateway.
- **Application Load Balancer** (internet-facing) with a target group on port 3000, target type `ip` (`instance` if ADR-0001 falls back to ECS on EC2). The health-check path starts as `/` but is chosen after measuring response time per route on the first deploy (see Risks).
- Listener :443 uses a **self-signed certificate** (Terraform `tls` provider, **RSA 2048** key, which ACM accepts and the ALB bills at the standard capacity-unit rate per the AWS ELB pricing page) imported into ACM. The ALB DNS name is unknown until the ALB exists, so the cert uses a placeholder CN and wildcard SAN; the ALB does not validate it. Listener :80 returns a 301 redirect to HTTPS.
- Tasks sit in public subnets with public IPs (needed to pull from ECR and ship logs without NAT or VPC endpoints). Their security group allows ingress on 3000 only from the ALB security group.
- No custom domain; the entry point is the ALB DNS name.

## Alternatives considered
| Option | Why not |
|---|---|
| Private subnets + NAT | Better posture, but NAT costs roughly $32/mo plus data per AZ for a short-lived demo. |
| Private subnets + VPC endpoints (ECR, S3, Logs) | Also a recurring per-endpoint cost. Right answer for production. |
| NLB | No HTTP-level `X-Forwarded-*` headers, and `bin/004` appears to look for ALB-style headers. |
| Route 53 + ACM-issued cert | Needs a domain we do not have, and may fail the `/loadbalanced` Host match (see Context). Test before recommending. |
| TLS terminated in the container | Moves cert management into the app image. |

## Tradeoffs
- (+) Cheap, simple, fully reproducible in Terraform. TLS terminated at the ALB.
- (-) Self-signed cert triggers browser warnings; clients need `curl -k`.
- (-) Public task IPs widen the surface versus private subnets and incur IPv4 charges (ADR-0008).
- (-) Traffic ALB to task is plain HTTP inside the VPC.

## Risks
1. `/tls` criteria are unknown; it may fail with a self-signed cert or an ALB-terminated setup.
2. `/loadbalanced` may depend on the Host header containing `elb.amazonaws.com`.
3. A task with an open security group is reachable directly.
4. Health checks flap if the health-check path is slow. `/` runs `bin/001`, which contains IMDSv2 cloud detection (`getIMDSv2Token`). [INFERENCE] On Fargate there is no IMDS, so that call may block until it times out. Not observed.

## Mitigations
1. Request `/tls` through the ALB right after the first apply; if it fails, inspect the output and record the finding in the README rather than guess.
2. Use the ALB DNS name for all checks; do not add a domain until `/loadbalanced` is confirmed with it.
3. Task SG has no CIDR ingress rules, only an SG reference to the ALB. Confirm by requesting the task public IP directly and expecting a timeout.
4. Measure `curl -w '%{time_total}'` for each route on the first deploy and use the fastest as the health-check path (`bin/005` has no HTTP client, so `/tls` is a candidate). Use a generous interval/timeout and a healthy threshold of 2.
