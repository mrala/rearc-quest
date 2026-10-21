# ADR-0007: Teardown

Status: Proposed

## Context

The README says we need not host the deployment long, and recommends tearing down within a week of submitting. ALB and Fargate bill hourly, so leaving them running costs real money.

## Decision

- **Everything is created by Terraform and destroyed by `make destroy`** (`terraform destroy`). No resource is created by hand.
- ECR repository uses `force_delete = true` so images do not block destruction.
- CloudWatch log group has a short retention (7 days) and is Terraform-managed, so it is removed with the stack.
- All resources carry tags `project=quest` and `ttl=<date>`, set via the provider's `default_tags`.
- A `make verify-clean` target lists any remaining resources with the `project=quest` tag (Resource Groups Tagging API).
- Screenshots of `/` and each check are captured **before** destroy.
- If ADR-0001 falls back to ECS on EC2, destroy also covers the Auto Scaling group, launch template, capacity provider, and instances; Terraform dependency order handles these, but confirm the instances are gone.
- `make verify-clean` is a safety net, not proof: the tagging API does not return every resource type and can lag. After destroy, also list by hand: load balancers, target groups, ECR repos, CloudWatch log groups, ACM certificates, ENIs, and the VPC.

## Alternatives considered

| Option | Why not |
|---|---|
| Manual console deletion | Error-prone; leaves orphans (ENIs, log groups). |
| Auto-expiry (scheduled Lambda/EventBridge destroys stack) | Extra infrastructure that must itself be torn down. |
| `aws-nuke` | Too broad a blast radius for a shared account. |
| Keep it running | Ongoing cost; no value after review. |

## Tradeoffs

- (+) One command, repeatable, verifiable by tag query.
- (-) Destroy requires intact Terraform state; loss of state leaves orphans.
- (-) `force_delete` on ECR discards the images (acceptable; rebuildable).

## Risks

1. Destroy fails or hangs (e.g. ENIs still attached, target group in use).
2. Destroy is run against the wrong account or region.
3. Orphans keep billing (ALB, Elastic IPs, log groups).
4. `verify-clean` misses a resource that the tagging API does not report, or that has not appeared yet.

## Mitigations

1. Fargate service `desired_count` is reduced as part of destroy order by Terraform dependencies; rerun `destroy` if an ENI delays release.
2. `make destroy` prints `aws sts get-caller-identity` and the region, and requires confirmation.
3. Run `make verify-clean` after destroy and check Cost Explorer the next day. Set the `ttl` tag as a reminder.
4. Run the manual checklist above (ELB, target groups, ECR, log groups, ACM, ENIs, VPC) in the console or CLI for the chosen region, and recheck in Cost Explorer the next day.
