#!/usr/bin/env bash
# Deploys one service of the stack in deploy/ to the EC2 host over SSH: deploy-ec2.sh <service>
# Logs the host in to GHCR with the job's token, pulls the new image and recreates only that container.
# Env: EC2_HOST, EC2_USER (default ubuntu), EC2_SSH_KEY, DEPLOY_DIR (on the host, relative to the
# user's home), GHCR_USER, GHCR_TOKEN
set -euo pipefail
service="$1"

if [ -z "${EC2_HOST:-}" ] || [ -z "${EC2_SSH_KEY:-}" ]; then
  echo "::warning::EC2_HOST / EC2_SSH_KEY secrets are not set; image pushed but not deployed."
  exit 0
fi

key=$(mktemp)
trap 'rm -f "$key"' EXIT
printf '%s\n' "$EC2_SSH_KEY" > "$key"
chmod 600 "$key"

# The token goes over stdin so it never appears in a command line on either machine
printf '%s' "$GHCR_TOKEN" | ssh -i "$key" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 \
  "${EC2_USER:-ubuntu}@${EC2_HOST}" \
  "set -e
   cd '${DEPLOY_DIR}'
   trap 'docker logout ghcr.io > /dev/null' EXIT
   docker login ghcr.io -u '${GHCR_USER}' --password-stdin > /dev/null
   docker compose pull '${service}'
   docker compose up -d '${service}'
   docker image prune -f > /dev/null"

echo "Deployed ${service} to ${EC2_HOST}"
