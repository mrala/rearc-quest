# Same verbs on every cloud (ADR-0010). Cloud-specific work lives in infra/$(CLOUD)/Makefile.
CLOUD        ?= aws
IMAGE        ?= quest
PLATFORM     ?= linux/amd64
# SHA tag, plus "-dirty" for uncommitted changes. Never "latest" (ADR-0004).
TAG          ?= $(shell git describe --always --dirty --abbrev=7)
LOCAL_PORT   ?= 3000
LOCAL_NAME   ?= quest-smoke

# Remote smoke test. The ALB certificate is self-signed, hence --insecure by default.
URL          ?= $(shell terraform -chdir=infra/$(CLOUD) output -raw url 2>/dev/null)
SMOKE_FLAGS  ?= -k

# Headers an ALB would add, so /tls and /loadbalanced can pass against a local container.
# This only exercises the app's header checks; a real ALB is the actual proof.
FORGED_ALB_HEADERS = -H 'X-Amzn-Trace-Id: Root=1-67891233-abcdef012345678912345678' \
	-H 'X-Forwarded-For: 203.0.113.9' -H 'X-Forwarded-Proto: https' -H 'X-Forwarded-Port: 443'

# AWS credentials come from the profile; the cloud Makefile reads these.
export AWS_PROFILE ?= quest-deployer
export AWS_REGION  ?= us-east-1

.DEFAULT_GOAL := help
.PHONY: help build run-local smoke-local smoke plan apply push destroy verify-clean

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'
	@echo "  plan apply push destroy verify-clean"
	@echo "                 Delegated to infra/$(CLOUD)/Makefile"
	@echo; echo "  CLOUD=$(CLOUD) TAG=$(TAG) AWS_PROFILE=$(AWS_PROFILE) AWS_REGION=$(AWS_REGION)"

build: ## Build the container image, tagged with the git SHA
	docker buildx build --platform $(PLATFORM) --provenance=false -t $(IMAGE):$(TAG) --load .

run-local: build ## Run the image on localhost, hardened like production
	-@docker rm -f $(LOCAL_NAME) >/dev/null 2>&1
	docker run -d --name $(LOCAL_NAME) --platform $(PLATFORM) -p $(LOCAL_PORT):3000 \
		--read-only --cap-drop ALL --security-opt no-new-privileges $(IMAGE):$(TAG)
	@echo "http://127.0.0.1:$(LOCAL_PORT)  (stop with: docker rm -f $(LOCAL_NAME))"

smoke-local: build ## Test a throwaway local container: forged ALB headers, skips / and /aws (need a cloud)
	-@docker rm -f $(LOCAL_NAME) >/dev/null 2>&1
	@docker run -d --name $(LOCAL_NAME) --platform $(PLATFORM) -p $(LOCAL_PORT):3000 \
		--read-only --cap-drop ALL --security-opt no-new-privileges \
		-e SECRET_WORD=local-test-word $(IMAGE):$(TAG) >/dev/null
	@for i in $$(seq 1 40); do curl -s -o /dev/null http://127.0.0.1:$(LOCAL_PORT)/nope && break; sleep 0.5; done; \
	EXPECT_SECRET_WORD=local-test-word tests/smoke.sh -s / -s /aws $(FORGED_ALB_HEADERS) http://127.0.0.1:$(LOCAL_PORT); rc=$$?; \
	docker rm -f $(LOCAL_NAME) >/dev/null 2>&1; exit $$rc

smoke: ## Run all six routes against URL (default: the cloud's `url` output)
	@test -n "$(URL)" || { echo "no URL: pass URL=https://... or apply infra/$(CLOUD) first" >&2; exit 1; }
	EXPECT_SECRET_WORD="$(EXPECT_SECRET_WORD)" tests/smoke.sh $(SMOKE_FLAGS) "$(URL)"

# The image is built before it is pushed or deployed.
apply push: build

plan apply push destroy verify-clean: ## Delegated to infra/$(CLOUD)/Makefile
	@test -f infra/$(CLOUD)/Makefile || { echo "infra/$(CLOUD)/Makefile does not exist yet" >&2; exit 1; }
	$(MAKE) -C infra/$(CLOUD) $@ IMAGE=$(IMAGE) TAG=$(TAG) TTL=$(TTL) AUTO_APPROVE=$(AUTO_APPROVE)
