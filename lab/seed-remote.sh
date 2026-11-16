#!/bin/bash
# Runs on the Teleport host, as root, from the directory holding the lab files.
# demo.sh ships this directory over SSM and calls it.
set -euo pipefail
cd "$(dirname "$0")"
set -a; . /etc/teleport-demo.env; set +a
export PATH="$PATH:/snap/bin"

echo "== Kubernetes workloads"
# An earlier version bound the group cluster-wide; a binding cannot change kind in place.
k3s kubectl delete clusterrolebinding oncall-readers-view --ignore-not-found
k3s kubectl apply -f k8s.yaml

echo "== Database users and data"
# The master password is read from Secrets Manager here and nowhere else. demo.sh removes the
# host's permission to read it as soon as this script returns.
PGPASSWORD=$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ARN" \
  --query SecretString --output text | jq -r .password)
export PGPASSWORD
psql "host=$DB_HOST port=5432 dbname=shop user=postgres sslmode=require" \
  -v ON_ERROR_STOP=1 -q -f seed.sql
unset PGPASSWORD

echo "== Teleport role and bot"
tctl create -f role-claude-oncall.yaml
tctl create -f bot-claude-oncall.yaml

echo "== Done"
k3s kubectl -n shop get pods
tctl get kube_server --format=text 2>/dev/null || true
tctl get db_server --format=text 2>/dev/null || true
