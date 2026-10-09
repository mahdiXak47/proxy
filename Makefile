# proxy — secure VLESS/REALITY relay. Root entry point for both sides.
SHELL      := /usr/bin/env bash
VAULT_PASS ?= $(HOME)/.ansible/vault-pass-proxy
EP         := shared/endpoints.yml

.DEFAULT_GOAL := help
.PHONY: help doctor lint secrets secrets-init exit-check exit-apply exit-verify \
        edge-render edge-sync edge-apply edge-verify client-link

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	 | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

## ---------------------------------------------------------------- validation

doctor: ## Check prerequisites and that no REPLACE_ME values remain
	@fail=0; \
	for c in ansible-playbook ansible-vault jq python3 rsync; do \
	  command -v $$c >/dev/null || { echo "MISSING: $$c"; fail=1; }; \
	done; \
	[[ -f "$(VAULT_PASS)" ]] || { echo "MISSING: vault password file $(VAULT_PASS)"; fail=1; }; \
	[[ -f shared/vault.yml ]] || { echo "MISSING: shared/vault.yml (run 'make secrets-init')"; fail=1; }; \
	if grep -rn 'REPLACE_ME' $(EP) exit/inventories 2>/dev/null; then \
	  echo "--> fill the values above before applying"; fail=1; fi; \
	[[ $$fail -eq 0 ]] && echo "doctor: ok" || { echo "doctor: NOT READY"; exit 1; }

lint: ## jq + xray -test + ansible syntax + cross-side consistency
	@jq -e . edge/config/xray-template.json >/dev/null && echo "lint: edge template JSON ok"
	@python3 scripts/check-consistency.py
	@cd exit && ansible-playbook playbooks/site.yml --syntax-check >/dev/null \
	 && echo "lint: ansible syntax ok"
	@command -v ansible-lint >/dev/null && { cd exit && ansible-lint -q || true; } \
	 || echo "lint: ansible-lint not installed (skipped)"

## ---------------------------------------------------------------- secrets

secrets-init: ## Generate the REALITY keypair + UUID into an encrypted shared/vault.yml
	@./scripts/init-secrets.sh

secrets: ## Edit the shared encrypted vault
	ansible-vault edit shared/vault.yml --vault-password-file $(VAULT_PASS)

## ---------------------------------------------------------------- exit (Turkey VM)

exit-check: ## Dry-run the exit playbook (no changes)
	cd exit && ansible-playbook playbooks/site.yml --check --diff

exit-apply: ## Apply the exit playbook  (KEEP A PROVIDER CONSOLE OPEN)
	cd exit && ansible-playbook playbooks/site.yml

exit-verify: ## Assert the exit node is serving correctly
	cd exit && ansible-playbook playbooks/verify.yml

## ---------------------------------------------------------------- edge (x-ui host)

edge-render: ## Render edge/.env from shared/ (run locally; vault pass stays here)
	./edge/scripts/render-env.sh

edge-sync: edge-render ## Push edge/ + rendered .env to the edge host over ssh
	@./scripts/edge-sync.sh

edge-apply: ## Install the Xray template into the panel DB on the edge host
	@./scripts/edge-remote.sh 'cd $$REPO/edge && ./scripts/apply-xray-template.sh'

edge-verify: ## Run end-to-end checks on the edge host
	@./scripts/edge-remote.sh 'cd $$REPO/edge && ./scripts/verify.sh'

client-link: ## Print a client VLESS URI template for the panel inbound
	@./scripts/client-link.sh
