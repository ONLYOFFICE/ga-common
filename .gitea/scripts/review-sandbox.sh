#!/usr/bin/env bash
# Isolated-container review sandbox helpers for claude-review.yml's "Run review" step; expects ANTHROPIC_API_KEY/CLAUDE_MODEL/CLAUDE_CODE_VERSION/CLAUDE_EFFORT/CLAUDE_MAX_BUDGET_USD from the job env.

# Names this run's sandbox resources (per-run, not fixed - fixed names let one concurrent PR's cleanup kill another's still-live sandbox) and pre-creates claude-output/.
name_sandbox_resources() {
  local RUN_TAG="${GITHUB_RUN_ID:-$$}"
  NET_NAME="claude-internal-$RUN_TAG"
  PROXY_NAME="egress-proxy-$RUN_TAG"
  SANDBOX_NAME="claude-review-$RUN_TAG"

  mkdir -p claude-output
  # Pre-create both files before anything below can fail and exit early under `set -e`, so Upload/Post always find real (if empty) files instead of none at all.
  touch claude-output/claude-output.json claude-output/claude-debug.log
}

# The sandbox/proxy are sibling containers on the HOST daemon, not child processes of this job, so cancelling the job doesn't stop them by itself - clean up on any exit path, signalled or not.
cleanup_sandbox() {
  docker rm -f "$PROXY_NAME" "$SANDBOX_NAME" > /dev/null 2>&1 || true
  docker network rm "$NET_NAME" > /dev/null 2>&1 || true
}

# Resolves the host path backing $PWD via self-inspect (docker run -v resolves on the HOST under DooD); sets HOST_OUTPUT_DIR empty if unresolved, so callers fall back to docker cp.
resolve_host_output_dir() {
  HOST_OUTPUT_DIR=""
  # Self-inspect by container ID, not hostname: this runner sets a custom --hostname unrelated to the container's real ID, so `docker inspect "$(hostname)"` never matched - the cgroup path always encodes the real ID regardless of hostname.
  local SELF_ID
  SELF_ID=$(grep -oE '[0-9a-f]{64}' /proc/self/cgroup 2>/dev/null | head -1 || true)
  [ -n "$SELF_ID" ] || SELF_ID="$(hostname)"
  # `?` on `.[]`/`.Destination` skips anything non-iterable/non-object instead of erroring, so an unexpected `.Mounts` shape just yields no match.
  local HOST_PWD
  HOST_PWD=$(docker inspect "$SELF_ID" --format '{{json .Mounts}}' 2>/dev/null | jq -er --arg pwd "$PWD" '
    [.[]? | select(.Destination? as $d | $pwd == $d or ($pwd | startswith($d + "/")))]
    | sort_by(-(.Destination | length)) | .[0]
    | if . then .Source + ($pwd | ltrimstr(.Destination)) else empty end
  ' 2>/dev/null || true)
  if [ -n "$HOST_PWD" ]; then
    HOST_OUTPUT_DIR="$HOST_PWD/claude-output"
  else
    echo "::warning::Could not resolve the host path backing $PWD via docker inspect - using docker cp instead of a bind mount for /output"
  fi
}

# Builds the isolated network + egress-restricted proxy + claude container, copies repo/review in, installs the CLI, hands it to the unprivileged "node" user. Expects NET_NAME/PROXY_NAME/SANDBOX_NAME/HOST_OUTPUT_DIR already set.
setup_sandbox() {
  docker network create --internal "$NET_NAME" > /dev/null
  mkdir -p /tmp/squid
  cat > /tmp/squid/squid.conf << 'EOF'
http_port 3128
acl allowed_dst dstdomain .npmjs.org api.anthropic.com
http_access allow allowed_dst
http_access deny all
EOF
  docker create --name "$PROXY_NAME" --network "$NET_NAME" ubuntu/squid:latest > /dev/null
  # `docker cp` streams content over the API, so it works under DooD regardless of whose filesystem the source is on, unlike `-v`.
  docker cp /tmp/squid/squid.conf "$PROXY_NAME":/etc/squid/squid.conf
  docker start "$PROXY_NAME" > /dev/null
  docker network connect bridge "$PROXY_NAME"
  sleep 2

  # /output is the ONLY bind mount into the sandbox (when HOST_OUTPUT_DIR resolved) - a dedicated empty dir, not the job's real workspace; falls back to no mount (docker cp afterward) otherwise.
  local OUTPUT_MOUNT_ARGS=()
  [ -n "$HOST_OUTPUT_DIR" ] && OUTPUT_MOUNT_ARGS=(-v "$HOST_OUTPUT_DIR:/output")
  docker run -d --name "$SANDBOX_NAME" --network "$NET_NAME" \
    "${OUTPUT_MOUNT_ARGS[@]}" \
    -e ANTHROPIC_API_KEY \
    -e CLAUDE_CODE_VERSION \
    -e CLAUDE_MODEL \
    -e CLAUDE_EFFORT \
    -e CLAUDE_MAX_BUDGET_USD \
    -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    -e HTTP_PROXY=http://$PROXY_NAME:3128 \
    -e HTTPS_PROXY=http://$PROXY_NAME:3128 \
    -e http_proxy=http://$PROXY_NAME:3128 \
    -e https_proxy=http://$PROXY_NAME:3128 \
    -e NO_PROXY=localhost,127.0.0.1 \
    -w /workspace \
    node:20-slim sleep infinity > /dev/null

  docker exec "$SANDBOX_NAME" mkdir -p /workspace /output
  docker cp repo/. "$SANDBOX_NAME":/workspace/
  # REVIEW.md does `Read ../review/UNCOVERED-REVIEW.md` relative to /workspace, so review/ has to be copied in too, as a sibling, or that Read fails.
  docker cp review/. "$SANDBOX_NAME":/review/
  echo "Files inside container: $(docker exec "$SANDBOX_NAME" sh -c 'find /workspace -type f | wc -l')"

  docker exec "$SANDBOX_NAME" npm install -g --no-fund --no-audit --no-update-notifier --loglevel=error "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION:-latest}"
  docker exec "$SANDBOX_NAME" sh -c 'echo "Running review with model: $CLAUDE_MODEL, effort: $CLAUDE_EFFORT (claude-code $(claude --version || echo unknown))"'
  # --dangerously-skip-permissions refuses to run as root, and docker cp leaves files root-owned - hand them to the built-in unprivileged "node" user.
  docker exec "$SANDBOX_NAME" chown -R node:node /workspace /output
  # Pre-accept the trust dialog for /workspace as the node user - otherwise the CLI ignores the reviewed repo's own .claude/settings.json permissions.allow/additionalDirectories entries and warns about it (moot for permissions.allow under --dangerously-skip-permissions, but additionalDirectories genuinely affects file-tool scope).
  echo '{"projects":{"/workspace":{"hasTrustDialogAccepted":true}}}' > /tmp/claude-trust.json
  docker cp /tmp/claude-trust.json "$SANDBOX_NAME":/home/node/.claude.json
  docker exec "$SANDBOX_NAME" chown node:node /home/node/.claude.json
}

# Runs claude -p unprivileged, pulls /output out (docker cp fallback if not bind-mounted), validates the result; returns non-zero (after an ::error::) on failure.
run_claude_review() {
  local rc=0
  # Single attempt, no CLI timeout: --max-budget-usd bounds cost, job timeout-minutes is the backstop, --debug-file is uploaded next step for post-mortem.
  # --disallowedTools Task: full access is a sandbox-safety call, not a cost one - a spawned subagent
  # starts with a fresh context instead of reusing the cheap cached one, and this trades money for wall-clock
  # (confirmed live: a 2-level-deep subagent fork drove one review's cost to $4.70 vs. the usual $0.15-0.30).
  docker exec --user node -w /workspace "$SANDBOX_NAME" bash -c '
    set -euo pipefail
    claude -p --model "$CLAUDE_MODEL" --effort "$CLAUDE_EFFORT" --max-budget-usd "$CLAUDE_MAX_BUDGET_USD" \
      --debug-file /output/claude-debug.log --output-format json --dangerously-skip-permissions \
      --disallowedTools "Task" \
      < claude-prompt.txt > /output/claude-output.json
  ' || rc=$?
  # If /output was bind-mounted from $HOST_OUTPUT_DIR, both sides already see the same files - no docker cp needed.
  if [ -z "$HOST_OUTPUT_DIR" ]; then
    docker cp "$SANDBOX_NAME":/output/claude-output.json ./claude-output/claude-output.json 2>/dev/null || true
    docker cp "$SANDBOX_NAME":/output/claude-debug.log ./claude-output/claude-debug.log 2>/dev/null || true
  fi
  [ -s claude-output/claude-output.json ] || echo '{}' > claude-output/claude-output.json

  if [ "$rc" -ne 0 ] || ! jq -e '.is_error == false and ((.result // "") | length > 0)' claude-output/claude-output.json > /dev/null 2>&1; then
    local subtype oom
    subtype=$(jq -r '.subtype // "unknown"' claude-output/claude-output.json 2>/dev/null || echo "unparsable")
    # rc 137 = SIGKILL (128+9) - the OOM killer, or (before per-run names) another job's cleanup; the sandbox is still alive here (cleanup_sandbox runs on the caller's EXIT trap, after this returns).
    oom=$(docker inspect "$SANDBOX_NAME" --format '{{.State.OOMKilled}}' 2>/dev/null || echo "unknown")
    echo "::error::Review failed (exit $rc, subtype: $subtype, OOMKilled: $oom)"
    echo "Result excerpt: $(jq -r '.result // empty' claude-output/claude-output.json 2>/dev/null | head -c 300 || true)"
    return 1
  fi
}

# Extracts+validates the model's fenced JSON into claude-structured.json (best-effort - post_review_and_set_status has its own fallback) and echoes a one-line summary.
summarize_claude_review() {
  jq -r '.result' claude-output/claude-output.json | python3 .gitea/scripts/extract-json.py > claude-structured.json || {
    echo "::warning::Could not extract a valid review JSON from the model's response — posting fallback"
    echo "Result tail: $(jq -r '.result // empty' claude-output/claude-output.json 2>/dev/null | tail -c 500 || true)"
  }
  local STATS FINDINGS COST USAGE
  STATS=$(jq -r '"\(.num_turns // "?") turns / \((.duration_ms // 0) / 1000 | round)s"' claude-output/claude-output.json)
  FINDINGS=$([ -s claude-structured.json ] && jq '.findings | length' claude-structured.json 2>/dev/null || echo '?')
  COST=$(jq -r '.total_cost_usd // 0 | (. * 1000 | round) / 1000' claude-output/claude-output.json)
  USAGE=$(jq -r '.modelUsage // {} | to_entries | map("\(.key): \(.value.inputTokens // 0)in/\(.value.outputTokens // 0)out") | join(", ")' claude-output/claude-output.json 2>/dev/null || echo "n/a")
  echo "Review OK: $STATS, $FINDINGS findings, \$$COST ($USAGE)"
}
