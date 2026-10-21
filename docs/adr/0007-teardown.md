# ADR-0007: Teardown

Status: Accepted (2026-10-20). Implemented in `infra/aws/Makefile` and **run on 2026-10-21**: 31 resources destroyed in 185 s. See "Result" at the end.

## Context

The README says we need not host the deployment long, and recommends tearing down within a week of submitting. ALB and Fargate bill hourly, so leaving them running costs real money.

## Decision

- **Everything is created by Terraform and destroyed by `make destroy`** (`terraform destroy`). No resource is created by hand.
- ECR repository uses `force_delete = true` so images do not block destruction.
- CloudWatch log group has a short retention (7 days) and is Terraform-managed, so it is removed with the stack.
- All resources carry tags `project=quest` and `ttl=<date>`, set via the provider's `default_tags`.
- A `make verify-clean` target queries each service for leftovers and also lists anything still tagged `project=quest` (Resource Groups Tagging API). It separates confirmed leftovers (`Error 1`) from tagging-API entries that may be lag (`Error 3`); see "Result".
- Screenshots of `/` and each check are captured **before** destroy.
- ECS on EC2 was not chosen (ADR-0001), so there is no Auto Scaling group, launch template or instance to confirm gone; the stack is Fargate tasks, an ALB and networking.
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
4. `verify-clean` misses a resource that the tagging API does not report, or flags one that is already gone because the tagging API lags. The second happened (see "Result").
5. The teardown path had never run, so a dependency or ENI problem would only show on the first attempt. It ran on 2026-10-21 without needing a rerun.

## Mitigations

1. Fargate service `desired_count` is reduced as part of destroy order by Terraform dependencies; rerun `destroy` if an ENI delays release.
2. `make destroy` goes through `infra/aws/Makefile`'s `guard`, which prints the AWS identity and region and refuses to run as the root user; Terraform then asks for confirmation (`AUTO_APPROVE=1` skips it).
3. Run `make verify-clean` after destroy (it separates confirmed leftovers from tagging-API lag) and check Cost Explorer the next day. Set the `ttl` tag as a reminder.
4. Run the manual checklist above (ELB, target groups, ECR, log groups, ACM, ENIs, VPC) in the console or CLI for the chosen region, and recheck in Cost Explorer the next day.
5. Done 2026-10-21: `make destroy` and `make verify-clean` were run once; the result is below.

## Result (teardown run on 2026-10-21)

- `make destroy` as `quest-deployer` (17:30:01Z to 17:33:06Z): the plan was 0 to add, 0 to change, 31 to destroy, and **31 were destroyed in 185 s with no error and no rerun.** The slowest step was the internet gateway (2 min 54 s), which waits for the tasks' public IPs and network interfaces to release; the ACM certificate took 17 s and the load balancer 9 s.
- Checked afterwards: no load balancers, target groups, ECR repository, log group, ACM certificate, VPC or IAM role; no leftover network interfaces or Elastic IPs; no ACTIVE ECS task definitions; the budget returned NotFound; the local state was empty; and the old URL no longer responded.
- **`make verify-clean` reported leftovers that were not leftovers.** Two and four minutes after the delete the tagging API still listed the deleted security group and its five rules and the ECS service and cluster. Direct checks showed the security group and rules NotFound, the cluster and service INACTIVE, and no VPC. It also listed the three deregistered ECS task definitions, which AWS keeps as INACTIVE indefinitely at no cost. The AWS documentation says GetResources returns "tagged or previously tagged" resources and gives no time limit for deleted ones, so no bound is claimed here.
- **Fix:** `verify-clean` now ignores task definitions and reports tagging-API-only entries as `RECHECK` (`Error 3`: recheck later) instead of a leftover (`Error 1`). Tested against the real post-teardown state (`Error 3`) and a stubbed leftover (`Error 1`).
- Not removed, by design: the `quest-deployer` user and `QuestDeployer` policy (`infra/aws/bootstrap/bootstrap.sh destroy` removes them), and the AWS service-linked roles for ECS and load balancing that were created on first use. The deployer cannot list IAM roles, so the service-linked roles are expected to remain but were not confirmed.
- Not verified: the real cost. Billing data lags about a day.
