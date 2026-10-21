# AWS implementation of the shared verbs (ADR-0010). Normally run through the
# top-level Makefile: `make plan`, `make apply`, `make push`, `make destroy`.
IMAGE        ?= quest
TAG          ?= $(shell git describe --always --dirty --abbrev=7)
TTL          ?=
AUTO_APPROVE ?=

export AWS_PROFILE ?= quest-deployer
export AWS_REGION  ?= us-east-1

TF       = terraform
TF_VARS  = -var image=$(IMAGE) -var image_tag=$(TAG) -var region=$(AWS_REGION) $(if $(TTL),-var ttl=$(TTL))
APPROVE  = $(if $(AUTO_APPROVE),-auto-approve)

.PHONY: guard init fmt validate plan apply push destroy verify-clean

# Show who is about to change the account, and refuse to run as root (ADR-0009).
guard:
	@arn=$$(aws sts get-caller-identity --query Arn --output text 2>/dev/null) || { \
		echo "no AWS session: run  aws login --profile $(AWS_PROFILE) --region $(AWS_REGION)" >&2; exit 1; }; \
	case "$$arn" in *:root) echo "refusing to run as the root user ($$arn)" >&2; exit 1;; esac; \
	echo "AWS identity: $$arn   region: $(AWS_REGION)   image: $(IMAGE):$(TAG)"

init:
	$(TF) init -input=false

fmt:
	$(TF) fmt -check -diff

validate: init
	$(TF) validate

plan: guard init
	$(TF) plan $(TF_VARS)

# The image must exist in ECR before the service starts tasks, so the repository is
# created first, the image is pushed, and then everything else is applied.
apply: guard init
	$(TF) apply $(APPROVE) -target=aws_ecr_repository.app $(TF_VARS)
	$(MAKE) push IMAGE=$(IMAGE) TAG=$(TAG)
	$(TF) apply $(APPROVE) $(TF_VARS)

push: guard
	@repo=$$($(TF) output -raw ecr_repository_url 2>/dev/null) || { \
		echo "no ECR repository yet: run  make apply" >&2; exit 1; }; \
	docker image inspect $(IMAGE):$(TAG) >/dev/null 2>&1 || { \
		echo "image $(IMAGE):$(TAG) not built: run  make build" >&2; exit 1; }; \
	aws ecr get-login-password | docker login --username AWS --password-stdin "$${repo%%/*}" && \
	docker tag $(IMAGE):$(TAG) "$$repo:$(TAG)" && docker push "$$repo:$(TAG)"

# Terraform asks for confirmation; only "yes" proceeds (ADR-0007).
destroy: guard init
	$(TF) destroy $(APPROVE) $(TF_VARS)

# Safety net after destroy (ADR-0007). Prints what is left; exits 1 if anything is.
# The tagging API is not exhaustive and can lag, so each service is also queried.
# The deployer's own IAM user and policy (infra/aws/bootstrap) are tagged project=quest
# but are not part of the stack, so they are excluded.
verify-clean: guard
	@left=0; \
	check() { if [ -n "$$2" ] && [ "$$2" != "None" ]; then echo "STILL THERE  $$1:"; echo "$$2" | tr '\t' '\n' | sed 's/^/    /'; left=1; else echo "clean        $$1"; fi; }; \
	check "tagged project=quest" "$$(aws resourcegroupstaggingapi get-resources --tag-filters Key=project,Values=quest --query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n' | grep -v -E 'policy/QuestDeployer|user/quest-deployer')"; \
	check "load balancers" "$$(aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName,'quest')].LoadBalancerArn" --output text)"; \
	check "target groups" "$$(aws elbv2 describe-target-groups --query "TargetGroups[?starts_with(TargetGroupName,'quest')].TargetGroupArn" --output text)"; \
	check "ECS clusters" "$$(aws ecs list-clusters --query "clusterArns[?contains(@,'/quest')]" --output text)"; \
	check "ECR repository" "$$(aws ecr describe-repositories --query "repositories[?repositoryName=='$(IMAGE)'].repositoryArn" --output text 2>/dev/null)"; \
	check "log groups" "$$(aws logs describe-log-groups --log-group-name-prefix /ecs/quest --query 'logGroups[].logGroupName' --output text)"; \
	check "ACM certificates" "$$(aws acm list-certificates --query "CertificateSummaryList[?starts_with(DomainName,'quest.')].CertificateArn" --output text)"; \
	check "VPCs" "$$(aws ec2 describe-vpcs --filters Name=tag:project,Values=quest --query 'Vpcs[].VpcId' --output text)"; \
	check "IAM role quest-task-exec" "$$(aws iam get-role --role-name quest-task-exec --query 'Role.Arn' --output text 2>/dev/null)"; \
	echo "Also check Cost Explorer tomorrow (ADR-0007)."; \
	exit $$left
