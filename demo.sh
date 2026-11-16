#!/usr/bin/env bash
# Launch, load, use and tear down the Teleport agent demo.
#
#   DOMAIN=teleport.example.com ACME_EMAIL=you@example.com ./demo.sh up
#   ./demo.sh seed        load the Kubernetes workloads, the database, the Teleport role and bot
#   ./demo.sh seed-close  remove the host's access to the database password, if a seed was cut short
#   ./demo.sh bot         get a one-time join token and write the local tbot config
#   ./demo.sh mcp [file]  write the MCP client config (database and Kubernetes, as the bot)
#   ./demo.sh tunnel      open a local database port as the bot, for psql
#   ./demo.sh env         print the settings that make tsh and kubectl act as the bot
#   ./demo.sh status      stack outputs and what DNS says
#   ./demo.sh run '...'   run a shell command on the host through Systems Manager
#   ./demo.sh restart     restart Teleport on the host (after setting the A record late)
#   ./demo.sh recordings  what each recorded database session holds: statements and errors
#   ./demo.sh down        delete the stack, then check that nothing is left
#   ./demo.sh audit       the leftover check on its own
#
# Optional settings for `up`:
#   HOSTED_ZONE_ID     Route 53 zone holding DOMAIN: the stack then manages the A record
#   ALERT_EMAIL        receives a budget alert
#   ACME_STAGING=true  test without spending Let's Encrypt quota (clients will not trust it)
#   IMAGE_ID           Ubuntu 24.04 amd64 image; default is the current one for the region
#   KEEP_ON_FAILURE=1  keep a failed stack up for debugging; delete it with `down`
# Everywhere: STACK (default teleport-demo), AWS_REGION (default eu-west-1).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK="${STACK:-teleport-demo}"
[[ "$STACK" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "STACK must be lowercase letters, digits and hyphens: RDS lower-cases names, and the leftover checks match on them." >&2; exit 1; }
export AWS_REGION="${AWS_REGION:-eu-west-1}"
export AWS_PAGER=""
TAG_KEY=project
K8S_MCP_VERSION="${K8S_MCP_VERSION:-0.0.67}"
STATE="$HERE/.state"
UBUNTU_IMAGE=/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id

die() {
  echo "$*" >&2
  exit 1
}

output() {
  aws cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

resource() {
  aws cloudformation describe-stack-resource --stack-name "$STACK" \
    --logical-resource-id "$1" --query StackResourceDetail.PhysicalResourceId --output text
}

# Run a script on the host and print what it printed. Fails if the script fails.
# Systems Manager runs scripts with sh unless they start with a shebang.
ssm_run() {
  local script="$1" instance id status
  instance="$(resource Host)"
  id="$(aws ssm send-command --instance-ids "$instance" \
    --document-name AWS-RunShellScript \
    --parameters "$(jq -n --arg c "$script" '{commands: ["#!/bin/bash", $c], executionTimeout: ["900"]}')" \
    --query Command.CommandId --output text)"
  local deadline=$((SECONDS + ${SSM_TIMEOUT:-1000}))
  while :; do
    if ! status="$(aws ssm get-command-invocation --command-id "$id" --instance-id "$instance" \
      --query Status --output text 2>&1)"; then
      # The invocation can take a moment to exist. Any other error is real: say so, do not wait on it.
      case "$status" in
        *InvocationDoesNotExist*) status=Pending ;;
        *) echo "Cannot read the result of the remote command: $status" >&2; return 1 ;;
      esac
    fi
    case "$status" in
      Pending | InProgress | Delayed)
        [ "$SECONDS" -lt "$deadline" ] || { echo "Remote command still $status after ${SSM_TIMEOUT:-1000} s" >&2; return 1; }
        sleep 2 ;;
      *) break ;;
    esac
  done
  aws ssm get-command-invocation --command-id "$id" --instance-id "$instance" \
    --query StandardOutputContent --output text
  if [ "$status" != Success ]; then
    aws ssm get-command-invocation --command-id "$id" --instance-id "$instance" \
      --query StandardErrorContent --output text >&2
    echo "remote command ended with status $status" >&2
    return 1
  fi
}

# Change one stack parameter and nothing else: same template, same values for the rest.
set_param() {
  local key="$1" value="$2" current k
  local args=()
  current="$(aws cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Parameters[?ParameterKey=='$key'].ParameterValue" --output text)"
  [ "$current" = "$value" ] && return 0
  for k in $(aws cloudformation describe-stacks --stack-name "$STACK" \
    --query 'Stacks[0].Parameters[].ParameterKey' --output text); do
    if [ "$k" = "$key" ]; then
      args+=("ParameterKey=$k,ParameterValue=$value")
    else
      args+=("ParameterKey=$k,UsePreviousValue=true")
    fi
  done
  aws cloudformation update-stack --stack-name "$STACK" --use-previous-template \
    --capabilities CAPABILITY_IAM --parameters "${args[@]}" >/dev/null
  aws cloudformation wait stack-update-complete --stack-name "$STACK"
  echo "$key is now $value"
}

show_failed_events() {
  aws cloudformation describe-stack-events --stack-name "$STACK" \
    --query "StackEvents[?ends_with(ResourceStatus, 'FAILED')].[LogicalResourceId,ResourceStatusReason]" \
    --output text >&2 || true
}

cmd_up() {
  : "${DOMAIN:?set DOMAIN to the public name of the cluster, e.g. teleport.example.com}"
  : "${ACME_EMAIL:?set ACME_EMAIL to the contact address for the ACME account}"
  if aws cloudformation describe-stacks --stack-name "$STACK" >/dev/null 2>&1; then
    die "Stack $STACK already exists. Use status, or down before a fresh up."
  fi
  local image ip rollback=()
  image="${IMAGE_ID:-$(aws ssm get-parameter --name "$UBUNTU_IMAGE" --query Parameter.Value --output text)}"
  [ -n "${KEEP_ON_FAILURE:-}" ] && rollback=(--disable-rollback)

  aws cloudformation create-stack --stack-name "$STACK" \
    --template-body "file://$HERE/cloudformation/teleport-demo.yaml" \
    --capabilities CAPABILITY_IAM \
    --tags "Key=$TAG_KEY,Value=$STACK" \
    ${rollback[@]+"${rollback[@]}"} \
    --parameters \
      "ParameterKey=DomainName,ParameterValue=$DOMAIN" \
      "ParameterKey=AcmeEmail,ParameterValue=$ACME_EMAIL" \
      "ParameterKey=AcmeStaging,ParameterValue=${ACME_STAGING:-false}" \
      "ParameterKey=HostedZoneId,ParameterValue=${HOSTED_ZONE_ID:-}" \
      "ParameterKey=AlertEmail,ParameterValue=${ALERT_EMAIL:-}" \
      "ParameterKey=ImageId,ParameterValue=$image" >/dev/null
  echo "Creating $STACK in $AWS_REGION with image $image. About 15 minutes, most of it the database."

  # The address exists within the first minute, long before the host boots. Teleport needs
  # the name to resolve by then, so this is the moment to set the record.
  until ip="$(resource Eip 2>/dev/null)" && [ -n "$ip" ] && [ "$ip" != None ]; do
    # A stack that fails before the address exists would otherwise be waited on forever.
    status="$(aws cloudformation describe-stacks --stack-name "$STACK" \
      --query 'Stacks[0].StackStatus' --output text 2>&1)" || die "Cannot read the stack: $status"
    case "$status" in
      *FAILED* | ROLLBACK* | DELETE*) show_failed_events; die "Stack creation failed ($status)." ;;
    esac
    sleep 3
  done
  if [ -z "${HOSTED_ZONE_ID:-}" ]; then
    echo
    echo "  Now create this DNS record, with the shortest TTL your provider offers:"
    echo "      $DOMAIN.   A   $ip"
    echo
  fi

  if ! aws cloudformation wait stack-create-complete --stack-name "$STACK"; then
    show_failed_events
    die "Stack creation failed."
  fi
  cmd_status
}

cmd_status() {
  local ip domain resolved
  ip="$(output ElasticIp)"
  domain="$(output ProxyAddress)"
  domain="${domain%:443}"
  resolved="$(dig +short "$domain" A | tail -1)"
  echo "stack        $STACK ($AWS_REGION)"
  echo "instance     $(output InstanceId)"
  echo "database     $(output DbEndpoint)"
  echo "seed access  $(output SeedAccess)"
  echo "elastic IP   $ip"
  if [ "$resolved" = "$ip" ]; then
    echo "DNS          $domain -> $ip"
  else
    echo "DNS          $domain resolves to '${resolved:-nothing}': create an A record to $ip"
    echo "             If the host already booted, run ./demo.sh restart once the record resolves."
  fi
}

# Load the lab. The host may read the database master password only while this runs: if the load
# fails or is interrupted, the access is removed again before the script ends.
SEED_CLOSED=1
close_seed_access() {
  [ "$SEED_CLOSED" = 1 ] && return 0
  echo "Seed did not finish: removing the host's access to the database password." >&2
  set_param SeedAccess disabled >&2 || echo "WARNING: could not remove it. Run: $0 seed-close" >&2
}

cmd_seed() {
  local bundle
  trap close_seed_access EXIT
  trap 'exit 130' INT TERM
  SEED_CLOSED=0
  set_param SeedAccess enabled
  bundle="$(tar -C "$HERE" -czf - lab | base64 | tr -d '\n')"
  ssm_run "rm -rf /opt/lab && echo '$bundle' | base64 -d | tar -xz -C /opt && bash /opt/lab/seed-remote.sh"
  set_param SeedAccess disabled
  SEED_CLOSED=1
  # IAM takes a few seconds to apply the change. Report success only when the host is refused with
  # AccessDenied: any other failure (no region, no network) proves nothing.
  ssm_run 'set -a; . /etc/teleport-demo.env; set +a
for i in $(seq 1 30); do
  if out="$(/snap/bin/aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ARN" --query Name --output text 2>&1)"; then
    sleep 2
  elif grep -q AccessDenied <<<"$out"; then
    echo "The host can no longer read the database master password."; exit 0
  else
    echo "Cannot tell whether the host can still read the password: $out" >&2; exit 1
  fi
done
echo "The host can still read the database master password." >&2; exit 1'
}

# Get a one-time join token for the bot (created by seed) and write the local tbot config.
cmd_bot() {
  local proxy token sym="" sym_storage=""
  proxy="${PROXY:-$(output ProxyAddress)}"
  token="$(ssm_run 'tctl bots instances add claude-oncall --format=json' | jq -r .token_id)"
  [ -n "$token" ] && [ "$token" != null ] || die "no join token returned"
  # macOS has no secure symlink support; saying so here stops tbot from warning on every start.
  if [ "$(uname)" = Darwin ]; then
    sym=$'\n      symlinks: insecure'
    sym_storage=$'\n  symlinks: insecure'
  fi
  rm -rf "$STATE/tbot"
  mkdir -p "$STATE/tbot"
  (umask 077; cat > "$STATE/tbot.yaml" <<EOF
version: v2
proxy_server: $proxy
onboarding:
  join_method: token
  token: $token
# Short-lived on purpose. The cluster caps the bot at 15 minutes whatever is asked here.
credential_ttl: 15m
renewal_interval: 5m
storage:
  type: directory$sym_storage
  path: $STATE/tbot/storage
services:
  # For the database MCP server: an identity file read by tsh.
  - type: identity
    # tsh derives a database certificate from this identity, so it must be reissuable.
    allow_reissue: true
    destination:
      type: directory$sym
      path: $STATE/tbot/identity
  # For kubernetes-mcp-server: a kubeconfig that calls tbot for a fresh certificate.
  - type: kubernetes/v2
    selectors:
      - name: demo-k3s
    destination:
      type: directory$sym
      path: $STATE/tbot/kube
  # For kubectl typed by hand: the same access, with the certificate written in the file.
  - type: kubernetes/v2
    disable_exec_plugin: true
    selectors:
      - name: demo-k3s
    destination:
      type: directory$sym
      path: $STATE/tbot/kube-static
  # For psql typed by hand, through \`demo.sh tunnel\`: one database, one name, one user.
  - type: database
    service: shop-rds
    database: shop
    username: oncall_ro
    destination:
      type: directory$sym
      path: $STATE/tbot/db
EOF
  )
  echo "Wrote $STATE/tbot.yaml. Start the bot with:"
  echo "  tbot start -c $STATE/tbot.yaml"
}

# Open a local port that reaches the database as the bot. Plain psql can then connect:
#   psql postgres://oncall_ro@127.0.0.1:15432/shop
# Stays in the foreground; stop it with Ctrl-C.
cmd_tunnel() {
  local proxy
  proxy="${PROXY:-$(output ProxyAddress)}"
  exec tbot proxy --proxy-server="$proxy" --destination-dir="$STATE/tbot/db" \
    db --port="${PORT:-15432}" --tunnel shop-rds
}

# Print the two settings that make tsh and kubectl act as the bot in the current shell.
cmd_env() {
  printf 'export TELEPORT_IDENTITY_FILE=%q\n' "$STATE/tbot/identity/identity"
  printf 'export KUBECONFIG=%q\n' "$STATE/tbot/kube-static/kubeconfig.yaml"
}

# Write an MCP client config with two servers, both running as the bot. No secret goes in it:
# it points at files that tbot rewrites every few minutes.
cmd_mcp() {
  local proxy out tsh tmp
  proxy="${PROXY:-$(output ProxyAddress)}"
  out="${1:-$STATE/mcp.json}"
  tsh="${TSH:-tsh}"
  # The file is written whole, so an existing client config (Claude Desktop, Cursor) would lose its
  # other servers. Replace only the file this script made itself, or when asked.
  if [ -e "$out" ] && [ "$out" != "$STATE/mcp.json" ] && [ -z "${MCP_OVERWRITE:-}" ]; then
    die "$out exists and would be replaced. Give a new path, or set MCP_OVERWRITE=1."
  fi
  mkdir -p "$(dirname "$out")"
  tmp="$(mktemp -u)"
  TELEPORT_IDENTITY_FILE="$STATE/tbot/identity/identity" "$tsh" mcp db config \
    --proxy="$proxy" --db-user=oncall_ro --db-name=shop --client-config="$tmp" shop-rds >/dev/null
  jq -e '.mcpServers["teleport-databases"]' "$tmp" >/dev/null \
    || die "tsh did not write a teleport-databases server. It wrote: $(jq -c '.mcpServers | keys' "$tmp")"
  jq --arg id "$STATE/tbot/identity/identity" --arg proxy "$proxy" \
     --arg kube "$STATE/tbot/kube/kubeconfig.yaml" --arg ver "$K8S_MCP_VERSION" '
    .mcpServers["teleport-databases"].env = {TELEPORT_IDENTITY_FILE: $id, TELEPORT_PROXY: $proxy}
    | .mcpServers.kubernetes = {
        command: "npx",
        args: ["-y", "kubernetes-mcp-server@\($ver)", "--kubeconfig", $kube,
               "--toolsets", "core", "--disable-multi-cluster"]
      }' "$tmp" > "$out.tmp" && mv "$out.tmp" "$out"
  rm -f "$tmp"
  echo "Wrote $out"
}

cmd_run() {
  ssm_run "$1"
}

# Teleport reads the name once at boot. If the A record was set after the host booted, its own
# reverse tunnel keeps dialing the old address and every query fails with "no db reverse tunnel".
cmd_restart() {
  ssm_run 'systemctl restart teleport; sleep 25; systemctl is-active teleport'
}

# Teleport keeps a recording for every database session. The audit log lists a refused statement as
# executed; the recording holds the database's error. This prints both for each session, so the
# web UI is not needed to check them. Recordings are downloaded to the host, not to this machine.
cmd_recordings() {
  ssm_run 'rm -rf /tmp/rec && mkdir /tmp/rec && cd /tmp/rec
for id in $(tctl recordings ls --last=${LAST:-2h} | awk "NR>2 {print \$1}"); do
  tctl recordings download "$id" >/dev/null 2>&1
done
python3 - <<"PY"
import glob, re, zlib
for path in sorted(glob.glob("/tmp/rec/*.tar")):
    data = open(path, "rb").read()
    # Each file starts with a 24-byte upload header, then a gzip stream of protobuf events.
    raw = zlib.decompressobj(31).decompress(data[data.find(b"\x1f\x8b\x08"):])
    queries = [q.decode() for q in re.findall(rb"(?:SELECT|ALTER|DROP|INSERT|UPDATE|DELETE|BEGIN)[ -~]{0,90}", raw)
               if not q.startswith(b"SELECT 1")]
    errors = [e.decode() for e in re.findall(rb"ERROR: [ -~]{0,80}", raw)]
    denied = b"TDB00W" in raw
    print(path.split("/")[-1][:8], "DENIED" if denied else "      ",
          "|", "; ".join(q.strip(":") for q in queries[:2]) or "-", "|", "; ".join(errors[:1]) or "no error")
PY'
}

# List what is still there. Each check must succeed and return nothing: a check that cannot
# run counts as a failure, never as "nothing found".
cmd_audit() {
  local left=0 account
  account="$(aws sts get-caller-identity --query Account --output text)"
  check() {
    local label="$1" found
    shift
    if ! found="$("$@" 2>&1)"; then
      left=1
      echo "ERROR $label: could not check: $(echo "$found" | tail -1)"
      return
    fi
    found="$(echo "$found" | tr '\t' '\n' | grep -vE '^(None)?$' || true)"
    if [ -n "$found" ]; then
      left=1
      echo "LEFT  $label: $(echo "$found" | tr '\n' ' ')"
    else
      echo "ok    $label"
    fi
  }
  # An account with no budget at all answers NotFoundException: that is "nothing left", not an error.
  budgets_left() {
    local out
    if ! out="$(aws budgets describe-budgets --account-id "$account" \
      --query "Budgets[?starts_with(BudgetName, '$STACK-')].BudgetName" --output text 2>&1)"; then
      grep -q NotFoundException <<<"$out" && return 0
      echo "$out"
      return 1
    fi
    echo "$out"
  }
  local tag="Name=tag:$TAG_KEY,Values=$STACK"
  check "stack" aws cloudformation list-stacks \
    --query "StackSummaries[?StackName=='$STACK' && StackStatus!='DELETE_COMPLETE'].StackStatus" --output text
  check "instances" aws ec2 describe-instances \
    --filters "$tag" Name=instance-state-name,Values=pending,running,stopping,stopped \
    --query 'Reservations[].Instances[].InstanceId' --output text
  check "volumes" aws ec2 describe-volumes --filters "$tag" --query 'Volumes[].VolumeId' --output text
  check "elastic IPs" aws ec2 describe-addresses --filters "$tag" --query 'Addresses[].PublicIp' --output text
  check "network interfaces" aws ec2 describe-network-interfaces --filters "$tag" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' --output text
  check "VPCs" aws ec2 describe-vpcs --filters "$tag" --query 'Vpcs[].VpcId' --output text
  check "security groups" aws ec2 describe-security-groups --filters "$tag" \
    --query 'SecurityGroups[].GroupId' --output text
  # The database is "<stack>-shop": match it exactly, so that a stack named "<stack>-two" is not flagged.
  check "database instances" aws rds describe-db-instances \
    --query "DBInstances[?DBInstanceIdentifier=='$STACK-shop'].DBInstanceIdentifier" --output text
  check "database snapshots" aws rds describe-db-snapshots \
    --query "DBSnapshots[?DBInstanceIdentifier=='$STACK-shop'].DBSnapshotIdentifier" --output text
  check "automated backups" aws rds describe-db-instance-automated-backups \
    --query "DBInstanceAutomatedBackups[?DBInstanceIdentifier=='$STACK-shop'].DBInstanceIdentifier" --output text
  check "database subnet groups" aws rds describe-db-subnet-groups \
    --query "DBSubnetGroups[?starts_with(DBSubnetGroupName, '$STACK')].DBSubnetGroupName" --output text
  check "secrets" aws secretsmanager list-secrets --include-planned-deletion \
    --query "SecretList[?Tags[?Key=='aws:rds:primaryDBInstanceArn' && contains(Value, ':db:$STACK')]].Name" --output text
  check "IAM roles" aws iam list-roles --query "Roles[?starts_with(RoleName, '$STACK-')].RoleName" --output text
  check "budgets" budgets_left
  check "log groups" aws logs describe-log-groups --log-group-name-prefix "/aws/rds/instance/$STACK" \
    --query 'logGroups[].logGroupName' --output text
  if [ "$left" -eq 0 ]; then
    echo "Nothing left behind."
  else
    echo "Not clean. See the LEFT and ERROR lines above." >&2
    return 1
  fi
}

cmd_down() {
  local domain="" zone="" rc=0
  domain="$(output ProxyAddress 2>/dev/null || true)"
  zone="$(aws cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Parameters[?ParameterKey=='HostedZoneId'].ParameterValue" --output text 2>/dev/null || true)"
  aws cloudformation delete-stack --stack-name "$STACK"
  echo "Deleting $STACK, this takes several minutes."
  aws cloudformation wait stack-delete-complete --stack-name "$STACK"
  rm -rf "$STATE"
  cmd_audit || rc=$?
  # A record left behind points at an address AWS can hand to someone else: say so whatever the audit found.
  # With HostedZoneId set, the stack owned the record and has already deleted it.
  if [ -n "$domain" ] && [ "$domain" != None ] && { [ -z "$zone" ] || [ "$zone" = None ]; }; then
    echo "Now delete the A record for ${domain%:443}: it points at an address you no longer own."
  fi
  return "$rc"
}

case "${1:-}" in
  up) cmd_up ;;
  status) cmd_status ;;
  seed) cmd_seed ;;
  seed-close) SEED_CLOSED=0; close_seed_access ;;
  bot) cmd_bot ;;
  mcp) cmd_mcp "${2:-}" ;;
  tunnel) cmd_tunnel ;;
  env) cmd_env ;;
  run) cmd_run "${2:?give a command to run}" ;;
  restart) cmd_restart ;;
  recordings) cmd_recordings ;;
  audit) cmd_audit ;;
  down) cmd_down ;;
  *) awk 'NR > 1 { if (/^#/) { sub(/^# ?/, ""); print } else exit }' "${BASH_SOURCE[0]}"; exit 2 ;;
esac
