# ADR-0003: Networking

Status: Accepted (2026-10-20). Implemented and verified on Fargate behind a real ALB.

## Context
Requirements: a load balancer in front of the app (task 6), HTTPS with locally generated certs allowed (task 7), a load-balanced check at `/loadbalanced`, and a TLS check at `/tls`.

Observed in `strings` of the supplied binaries:
- `bin/004` contains `elb.amazonaws.com`, `X-Amzn-Trace-Id`, `X-Forwarded-For`, and separate success messages for GCP and Azure load balancers. An AWS ALB is therefore a recognised case.
- Verified locally with forged headers (2026-10-20): `/loadbalanced` passes with `X-Amzn-Trace-Id`, `X-Forwarded-For`, `X-Forwarded-Proto` and `X-Forwarded-Port` and a `localhost` Host header, and fails with `X-Forwarded-For` alone. A Host match is therefore not required. I did not isolate which of the other headers is required.
- Verified locally: `/tls` passes when `X-Forwarded-Proto: https` is present. Only a real ALB proves the header arrives.

## Decision
- New VPC with **2 public subnets in 2 AZs**, an internet gateway, and no NAT gateway.
- **Application Load Balancer** (internet-facing) with a target group on port 3000, target type `ip` (`instance` if ADR-0001 falls back to ECS on EC2). The health-check path is a fast route such as `/tls`, `/docker` or `/secret_word` (about 50 ms locally), never `/` (about 25 s locally) or `/loadbalanced` (about 5 s). Re-measure on AWS.
- Listener :443 uses a **self-signed certificate** (Terraform `tls` provider, **RSA 2048** key, which ACM accepts and the ALB bills at the standard capacity-unit rate per the AWS ELB pricing page) imported into ACM. The ALB DNS name is unknown until the ALB exists, so the cert uses a placeholder CN and wildcard SAN; the ALB does not validate it. Listener :80 returns a 301 redirect to HTTPS.
- Tasks sit in public subnets with public IPs (needed to pull from ECR and ship logs without NAT or VPC endpoints). Their security group allows ingress on 3000 only from the ALB security group.
- No custom domain; the entry point is the ALB DNS name.

## Alternatives considered
| Option | Why not |
|---|---|
| Private subnets + NAT | Better posture, but NAT costs roughly $32/mo plus data per AZ for a short-lived demo. |
| Private subnets + VPC endpoints (ECR, S3, Logs) | Also a recurring per-endpoint cost. Right answer for production. |
| NLB | No HTTP-level `X-Forwarded-*` headers, and `bin/004` appears to look for ALB-style headers. |
| Route 53 + ACM-issued cert | Needs a domain we do not have. A Host match is not required locally, but test on AWS before recommending. |
| TLS terminated in the container | Moves cert management into the app image. |

## Tradeoffs
- (+) Cheap, simple, fully reproducible in Terraform. TLS terminated at the ALB.
- (-) Self-signed cert triggers browser warnings; clients need `curl -k`.
- (-) Public task IPs widen the surface versus private subnets and incur IPv4 charges (ADR-0008).
- (-) Traffic ALB to task is plain HTTP inside the VPC.

## Risks
1. `/tls` depends on `X-Forwarded-Proto: https` reaching the app. **Verified 2026-10-20:** `/tls` passes through the real ALB.
2. `/loadbalanced` needs ALB-style headers (`X-Amzn-Trace-Id` and others). **Verified 2026-10-20:** passes through the real ALB.
3. A task with an open security group is reachable directly. **Verified 2026-10-20:** neither task public IP answered on port 3000 within 6 s.
4. Health checks flap if the health-check path is slow. Locally `/` takes about 25 s and `/loadbalanced` about 5 s (cloud detection). On Fargate `/` takes 0.5 to 1.8 s and the rest about 0.1 to 0.2 s; both tasks are healthy on `/tls`.

## Mitigations
1. Done 2026-10-20: `/tls` requested through the ALB right after the first apply; it passed.
2. Done: every check used the ALB DNS name, and no domain was added. A real domain remains untested.
3. Done: the task security group has no CIDR ingress rules, only a reference to the ALB's security group, and the direct-access test timed out as intended.
4. Done: `/tls` is the health-check path with a 30 s interval, 10 s timeout and a healthy threshold of 2.
