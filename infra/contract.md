# Cloud contract

What every cloud root under `infra/<cloud>/` implements (ADR-0010). The contract was
written from one cloud (AWS), so treat it as provisional until a second cloud exists and
revise it then.

## Inputs (Terraform variables)

| Name | Type | Meaning |
|---|---|---|
| `image` | string | Image name (on AWS also the registry repository name) |
| `image_tag` | string | Tag to deploy, normally the git SHA. Never `latest`. |
| `secret_word` | string, sensitive | Value of the `SECRET_WORD` env var. Empty means not set. |
| `replicas` | number | Number of instances, at least 2 for a meaningful load balancer demo |
| `tags` | map(string) | Extra tags or labels on every resource |

Everything else is cloud specific (AWS: `region`, `cpu`, `memory`, `health_check_path`,
`vpc_cidr`, `ttl`, `log_retention_days`, `budget_email`, `budget_limit_usd`).

## Outputs

| Name | Meaning |
|---|---|
| `url` | Base URL of the deployment, passed to `tests/smoke.sh` |
| `lb_hostname` | DNS name of the load balancer |

## Behaviour every cloud must provide

- A load balancer in front of two or more instances, and HTTPS (a self-signed certificate is fine).
- Plain HTTP redirects to HTTPS.
- The container is not reachable except through the load balancer.
- `SECRET_WORD` reaches the container as an environment variable only when `secret_word` is non-empty.
- One command to remove everything: `make destroy`.

## Makefile verbs

The top-level `Makefile` delegates `plan`, `apply`, `push`, `destroy` and `verify-clean` to
`infra/$(CLOUD)/Makefile`. `build`, `smoke` and `smoke-local` are cloud neutral.

## Acceptance test

`tests/smoke.sh <url>` checks all six routes. The routes report cloud-specific text, so a
second cloud passes the same checks with different output; record any difference instead
of masking it.
