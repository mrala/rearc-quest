# ADR-0008: Cost controls

Status: Proposed

## Context
The quest says it should be achievable at zero or near-zero cost. ALB, Fargate (or EC2), public IPv4 addresses, and CloudWatch Logs bill by usage. Per the AWS ELB pricing page, accounts created since July 15, 2025 get up to $200 in credits and a 6-month "free plan" instead of the older 750 ALB hours; older accounts may still have the 750 hours. Check which applies to your account. I did not check whether the free plan restricts any service we need.

Rough estimate for us-east-1. The ALB rate ($0.0225/hr plus $0.008 per LCU-hour) and the Fargate x86 rates ($0.000011244 per vCPU-second, $0.000001235 per GB-second) are taken from the AWS ELB and Fargate pricing pages (read 2026-10-20). The public IPv4 rate is **not** shown on those pages and is from memory.

| Item | Approx. per day |
|---|---|
| ALB (hourly, minimal LCUs) | ~$0.55 |
| 2 Fargate tasks, 0.25 vCPU / 0.5 GB | ~$0.60 |
| Public IPv4 addresses (2 on the ALB, 1 per task = 4 at ~$0.005/hr, rate from memory) | ~$0.50 |
| Logs, ECR, data transfer | small |
| **Total** | **~$1.5 to $2** |

Verify with the AWS Pricing Calculator for your region before the first apply. The ECS-on-EC2 fallback (ADR-0001) changes the compute line.

## Decision
- **Smallest Fargate size** (0.25 vCPU / 512 MB) and **2 tasks** (the minimum for a meaningful load balancer demo).
- **No NAT gateway, no VPC endpoints, no EKS** (ADR-0001, ADR-0003).
- **No autoscaling**; fixed `desired_count`.
- CloudWatch log retention 7 days; ECR lifecycle policy keeps the last 5 images.
- **AWS Budget** with an email alert at 80% of a small monthly limit (for example $10) and a forecasted alert, defined in Terraform.
- `default_tags` (`project`, `ttl`) so costs are attributable in Cost Explorer.
- Deploy only for the review window, then destroy (ADR-0007).

## Alternatives considered
| Option | Why not |
|---|---|
| Fargate Spot | Interruptions undermine a demo that must be up when reviewed. |
| Single task | Cheaper, but `/loadbalanced` shows nothing. |
| Run only locally | Fails the public-cloud requirement. |
| Hard spending cap | AWS Budgets alert but do not stop spend unless Budget Actions are configured; those need extra IAM and are overkill here. |

## Tradeoffs
- (+) Low, bounded, predictable spend.
- (-) 0.25 vCPU is slow; each request execs a binary and may be sluggish under load.
- (-) Budgets are lagging alerts (billing data is delayed), not hard limits.
- (-) Public IPv4 charges are the cost of skipping NAT and endpoints.

## Risks
1. Forgetting to destroy; costs accrue past the review.
2. Task too small, causing health-check failures and restart loops.
3. The estimate above is wrong for the account or region.
4. The Fargate gate (ADR-0001) pushes us to EC2, changing the cost.

## Mitigations
1. `ttl` tag, budget alerts, and a calendar reminder; teardown is one command.
2. Raise to 0.5 vCPU / 1 GB if health checks flap; the cost difference is small.
3. Check the Pricing Calculator before the first apply, and Cost Explorer after the first day.
4. Re-run the estimate if the compute choice changes.
