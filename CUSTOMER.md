# Deploying the Quest app on AWS

This repository deploys the Rearc Quest web app to your AWS account: a container on ECS Fargate behind an
Application Load Balancer with HTTPS, defined entirely in Terraform. It is a reference deployment for
evaluation and short-lived use. [What it is not](#what-this-is-not-yet) lists what to add before running it
for real.

A deployment takes about 15 minutes end to end, most of it waiting for the image build and for AWS.

## What you get

```
Internet ──► ALB (80 redirects to 443; self-signed certificate, TLS 1.3)
                 │ HTTP 3000
        ┌────────┴────────┐
   Fargate task       Fargate task        two tasks, one per availability zone
   (us-east-1a)       (us-east-1b)        0.25 vCPU / 512 MiB each, no task role
```

- A new VPC with two public subnets and no NAT gateway. Tasks have public IPs only so they can pull the image
  and reach the internet; their security group accepts port 3000 from the load balancer and nothing else.
- An ECR repository, a CloudWatch log group (7 days), and a task-execution IAM role.
- Rolling deployments with an automatic rollback if a new version fails to start.
- 31 Terraform-managed resources in total. Every resource that supports tags is tagged `project=quest`.

## Before you begin

| You need | Notes |
|---|---|
| An AWS account and one-time admin access | Used once, to create a limited deploy user. Not used afterwards. |
| AWS CLI 2.32 or later | For `aws login`. Any other way to sign in as a non-root identity also works. |
| Terraform 1.9 or later | 1.16.6 is what this was built and tested with (`.tool-versions`). |
| Docker with buildx | The image is built for `linux/amd64` because the app's bundled binaries are x86-64 only. On Apple Silicon this runs under emulation: the first build takes a minute or two. |
| `make`, `git`, `curl`, `bash` | Standard on macOS and Linux. |

**Region.** The deploy user's policy only allows `us-east-1`. To use another region, change the region in
`infra/aws/bootstrap/quest-deployer-policy.json` (two places) and set `region` in `terraform.tfvars`. This
has not been tried.

**Cost.** Estimated at **$1.5 to $2 a day** in `us-east-1`: the load balancer, two small tasks and four public
IPv4 addresses. The load balancer and Fargate rates come from the AWS pricing pages; the IPv4 rate is from memory
and actual spend was not measured. Remove the stack when you are done (see [Teardown](#teardown)).

## Deploy

### 1. Get the code

Use one of three ways. All give the same files; the first two keep the git history, which the Makefile uses
to name each image.

**a) Clone the repository** (you need access to it):

```
git clone <repository URL> quest
cd quest
```

**b) Extract a compressed copy that includes `.git`** (a `.tgz` or `.zip` of the whole project directory):

```
tar xzf rearc-quest.tgz        # or: unzip rearc-quest.zip
cd rearc-quest
ls -a                          # a .git directory must be listed
git status                     # should say: nothing to commit, working tree clean
```

With `.git` present, `make` needs no extra options. If the scripts lose their executable bit in extraction
(some zip tools drop it), run `chmod +x tests/smoke.sh infra/aws/bootstrap/bootstrap.sh`.

**c) Extract a copy without `.git`** (for example a zip downloaded from GitHub, or the output of
`git archive`). The Makefile names each image after the current git commit. Without `.git` it prints
`fatal: not a git repository` and tries to build an image tagged `quest:` with nothing after the colon, which
Docker rejects. Either pass a label yourself on every `make` command, using a new label for each version you
deploy (it becomes the image tag; never `latest`):

```
make apply TAG=2026-10-21a
make smoke-local TAG=2026-10-21a
```

or turn the folder into a repository once and use the commit as the label:

```
git init && git add -A && git commit -m "import"
```

### 2. Create the deploy identity (once)

Terraform should not run as the root user, and the Makefile refuses to. With admin credentials:

```
infra/aws/bootstrap/bootstrap.sh
```

This validates and creates the IAM policy `QuestDeployer` and the IAM user `quest-deployer`. The policy allows
only the services this stack uses, in one region; limits IAM to roles named `quest-*`; and denies creating
users, access keys and other policies. It needs `access-analyzer:ValidatePolicy` and IAM write access. Re-running
it updates the policy in place.

Then, in the IAM console, open the user, enable console access with a password, and add an MFA device. Sign in
from the command line:

```
aws login --profile quest-deployer --region us-east-1
```

Check that you are not root: `aws sts get-caller-identity --profile quest-deployer` should end in
`user/quest-deployer`. Sessions last up to 12 hours; run `aws login` again when one expires. If the CLI later
complains that no region is set, run `export AWS_REGION=us-east-1` in that shell (the Makefile sets it for you).

If you use IAM Identity Center or another sign-in method, you can skip the user and run with any non-root
profile that has equivalent permissions (use `quest-deployer-policy.json` as the reference), passing
`AWS_PROFILE=<profile>` to every `make` command. This has not been tried.

### 3. Configure

```
cp infra/aws/terraform.tfvars.example infra/aws/terraform.tfvars
```

`terraform.tfvars` is gitignored. Optional settings:

```
budget_email = "you@example.com"   # AWS Budget alerts; leave empty to skip the budget
ttl          = "2026-12-31"        # tagged on every resource as a reminder to remove the stack
```

The budget covers the whole account, not just this stack.

### 4. Deploy

```
make apply
```

This builds the image, creates the ECR repository, pushes the image, then creates everything else. Terraform
asks for confirmation twice, once for the repository and once for the rest (`AUTO_APPROVE=1` skips both). The
image is tagged with the git commit, never `latest`. Wait for the tasks to start (about 3 minutes), then:

```
make smoke
```

The base URL is in the Terraform output. Keep it in a variable for the commands below:
`URL=$(terraform -chdir=infra/aws output -raw url)`.

### 5. Set the secret word

The app shows a "secret word" on its index page only when it detects it is running in a cloud, so this takes a
second deploy. Open the URL (`curl -k "$URL/"`, using the `URL` variable from the previous step), then add the word to `infra/aws/terraform.tfvars`:

```
secret_word = "<the word from the index page>"
```

and run `make apply` again. The service rolls over in 3 to 4 minutes. The word is passed to the container as
the `SECRET_WORD` environment variable.

## Check that it works

```
make smoke                                   # all six routes
EXPECT_SECRET_WORD=<word> make smoke         # also checks /secret_word prints that word
```

The certificate is self-signed, so use `curl -k` (the Makefile already does) or accept the browser warning.

| Route | Expected |
|---|---|
| `/` | The secret word |
| `/aws` | "You are running in AWS, Detected: ECS,AWS" |
| `/docker` | **Fails on Fargate:** "You dont seem to be running in a Docker container". Expected; see below. |
| `/secret_word` | "Congratulations. Secret word is: <word>" once step 5 is done |
| `/loadbalanced` | "...configured an AWS loadbalancer" |
| `/tls` | "...configured TLS (https)" |

**Five of six pass.** `/docker` only checks for the file `/.dockerenv`, which Docker creates and Fargate does
not. The same image passes `/docker` on a plain Docker host, so the image is fine. Passing it on AWS would need
ECS on EC2, which this repository does not implement. Do not create the file in the image to silence the check.

To try the app without AWS, `make smoke-local` builds the image, runs it with the same restrictions, and checks
the four routes that work outside a cloud.

## Operating it

| Task | How |
|---|---|
| Follow the logs | `aws logs tail /ecs/quest --follow --profile quest-deployer` |
| Check the service | `aws ecs describe-services --cluster quest --services quest --profile quest-deployer` |
| Deploy a code change | Commit it, then `make apply`. The new commit becomes the image tag. |
| Change the number of tasks | Set `replicas` in `terraform.tfvars`, then `make apply` |
| Change task size | Set `cpu` and `memory` (they must be a valid Fargate pair), then `make apply` |
| Preview a change | `make plan` |

**Rolling back.** A deployment that fails to start rolls back automatically; this is configured but was not
triggered during testing. To go back to an earlier version, check out that commit and run `make apply`. Only the
last five images are kept in ECR.

**State.** Terraform state is a local file, `infra/aws/terraform.tfstate`. It holds the TLS private key and the
secret word in plain text. Keep it private, back it up, and do not commit it. Losing it means resources must be
removed by hand.

**The certificate is valid for 30 days.** It is self-signed, so clients already have to skip verification
(`curl -k`), and expiry changes nothing for them. It matters only if you add the certificate to a trust store or
pin it. Terraform should replace it when you run `make apply` in the last 24 hours before expiry or after it;
this was not tested. For anything longer-lived, use an ACM-issued certificate for your own domain instead.

## Configuration reference

Set in `infra/aws/terraform.tfvars`.

| Variable | Default | Meaning |
|---|---|---|
| `secret_word` | empty | Value of `SECRET_WORD`. Sensitive. |
| `replicas` | `2` | Number of tasks, spread over two zones |
| `cpu`, `memory` | `256`, `512` | Fargate task size (CPU units, MiB) |
| `health_check_path` | `/tls` | Load balancer health check. Keep it a fast route: `/` can take seconds. |
| `region` | `us-east-1` | See the note on regions above |
| `vpc_cidr` | `10.20.0.0/16` | Two /24 subnets are carved from it |
| `log_retention_days` | `7` | CloudWatch log retention |
| `tags` | `{}` | Extra tags on every resource |
| `ttl` | empty | Removal-date tag |
| `budget_email`, `budget_limit_usd` | empty, `"10"` | Budget alert address and monthly limit |
| `image` | `quest` | Image and ECR repository name |

`image_tag` is set by the Makefile from the git commit. Makefile options: `AWS_PROFILE` (default
`quest-deployer`), `AWS_REGION`, `AUTO_APPROVE=1`, `TTL=<date>`, `URL=<base url>` for `make smoke`.

## Teardown

```
make destroy          # Terraform shows the plan and asks for confirmation
make verify-clean     # lists anything still tagged project=quest; exits 1 if something is left
```

If you also want to remove the deploy user, do it **after** the stack is gone, since the stack's removal needs
its permissions:

```
infra/aws/bootstrap/bootstrap.sh destroy      # run with admin credentials
```

`make destroy` removes the images and logs too. **Teardown was not run in the reference deployment**, so if
`destroy` stops on a dependency (for example a network interface that has not released yet), wait a minute and run
it again. Check Cost Explorer the next day for anything still billing.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `no AWS session` | The `aws login` session expired. Run `aws login --profile quest-deployer --region us-east-1`. |
| `refusing to run as the root user` | By design. Use the `quest-deployer` profile or another non-root one. |
| `AccessDenied` during `plan` or `apply` | The policy is missing an action. Add it to `quest-deployer-policy.json`, re-run `bootstrap.sh`, and retry. Do not switch to root. |
| `make smoke`: "no URL" | Nothing is deployed yet, or the state file is missing. Run `make apply`, or pass `URL=https://...`. |
| `/secret_word` says "SECRET_WORD not found" | Step 5 is not done. Set `secret_word` and run `make apply`. |
| `/` shows `panic: ... x509: certificate signed by unknown authority` | The image has no CA certificates. The `Dockerfile` installs them; this appears if you changed the base image. |
| Tasks keep restarting, or `exec format error` in the logs | The image is not `linux/amd64`. The `Dockerfile` pins it; check that Docker buildx and emulation work. |
| Service does not become steady | Look at the service events (`aws ecs describe-services`), the target health (`aws elbv2 describe-target-health --target-group-arn ...`) and the logs. |
| `terraform init` fails with a checksum error | Provider checksums for linux and macOS (amd64 and arm64) are in the lock file. On another platform, run `terraform -chdir=infra/aws providers lock -platform=<os>_<arch>`. |
| Browser shows a certificate warning | Expected: the certificate is self-signed. |

## What this is not (yet)

Know these before using it beyond an evaluation:

- **The app has a command-injection flaw.** It builds shell commands from request headers, so a crafted header
  can run commands in the container. The app is third-party code and is deployed unmodified. The deployment
  limits the damage (non-root, read-only filesystem, no Linux capabilities, no task role, ingress only from the
  load balancer) but does not remove the risk, and injected code can still read the task's environment and make
  outbound connections. Do not expose it to untrusted users.
- **The load balancer is open to the internet.** To restrict it, change the source address in the two
  `alb_http` and `alb_https` rules in `infra/aws/network.tf`.
- **Task egress is open.** Tasks must reach the internet (the app fetches its secret word over HTTPS), and
  outbound rules were not tightened.
- **Tasks have public IPs and the certificate is self-signed.** Production should use private subnets with VPC
  endpoints (or NAT) and a certificate for your own domain.
- **State is local and secrets are in it.** Use a remote backend with encryption and locking, and a secrets
  service for the secret word.
- **Deploys are manual.** A GitHub Actions workflow checks formatting, validation and a local smoke test on
  pull requests and on pushes to `master`; nothing deploys automatically.
- **No alarms, autoscaling or access logs.**

`SOLUTION.md` has the findings, the reasoning and a longer list of improvements. `docs/adr/` has the design
decisions with their alternatives.

## Sharing a copy of the repository

To give the project to someone without repository access, make the copy from a **fresh clone**, never from
your working directory. A working directory can hold files that must not be shared: Terraform state
(`infra/aws/terraform.tfstate`, which contains the TLS private key and the secret word), `terraform.tfvars`,
`.terraform/` and `node_modules/`. A fresh clone contains only committed files.

```
git clone --no-local --single-branch --branch master . /tmp/export/rearc-quest   # run from inside the repository
git -C /tmp/export/rearc-quest remote remove origin   # the clone's origin is a path on your machine
tar czf rearc-quest.tgz -C /tmp/export rearc-quest    # or: (cd /tmp/export && zip -qr ~/rearc-quest.zip rearc-quest)
```

Use your main branch's name in place of `master` if it differs. `--no-local --single-branch` matters: a plain
local clone copies the whole object store, including commits from branches you deleted or never pushed (for
example a backup branch), and those travel inside `.git` even after the clone's branches are removed. This form
copies only the history reachable from the named branch.

The archive keeps `.git` and that history, and is about 60 MB, mostly the app's bundled binaries. Before
sending it, check that none of the private files are inside (this should print nothing):

```
tar tzf rearc-quest.tgz | grep -E 'tfstate|terraform\.tfvars$|\.terraform/|node_modules'
```

Other forms:

- **One file with the history:** `git bundle create rearc-quest.bundle master` (name the branch; `--all` would
  also pack every other branch). The recipient runs `git clone rearc-quest.bundle quest`.
- **Source only, no history:** `git archive --format=zip --prefix=rearc-quest/ -o rearc-quest-source.zip HEAD`.
  The recipient then follows option c) above and must pass `TAG=...` to `make`.

Commit author names and emails are part of the history and are shared with it. Review them first, for example
with `git log --format='%an <%ae>' | sort -u`.

## Repository layout

```
Dockerfile              the image (node:24-slim, non-root, tini, CA certificates)
src/, bin/              the Quest app and its bundled binaries (unmodified)
infra/aws/              Terraform and the AWS Makefile
infra/aws/bootstrap/    creates the deploy user and its policy
tests/smoke.sh          checks all six routes against any URL
Makefile                build, smoke, plan, apply, destroy, verify-clean
```
