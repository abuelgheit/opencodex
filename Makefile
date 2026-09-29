.PHONY: install vps-dry-run vps-copy vps-deploy

install:
	./scripts/install-local-global.sh

# Validate and stage the snapshot locally; performs no VPS access.
vps-dry-run:
	./scripts/copy-ocx-vps.sh --dry-run

# Copy the snapshot and deployment script to the VPS after the script's typed-IP confirmation;
# does not deploy.
vps-copy:
	./scripts/copy-ocx-vps.sh

# Copy to the VPS and run the remote deployment script after the same typed-IP confirmation.
vps-deploy:
	./scripts/copy-ocx-vps.sh --run-remote
