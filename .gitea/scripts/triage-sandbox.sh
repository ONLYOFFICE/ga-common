#!/usr/bin/env bash
# Isolated-container sandbox helpers for bugzilla-triage.yml's "Run triage" step; expects
# ANTHROPIC_API_KEY/CLAUDE_MODEL/CLAUDE_CODE_VERSION/CLAUDE_EFFORT/CLAUDE_MAX_BUDGET_USD from the job env.
# Optional tuning: SANDBOX_PIDS_LIMIT (default 1024), SANDBOX_MEMORY (unset = no ceiling).
#
# Deliberately a sibling of review-sandbox.sh rather than a shared refactor of it: that file is the
# battle-tested path for every repo's PR review, and the differences here are structural (several
# repositories side by side under /workspace instead of one, its own prompt/schema paths), not
# parameters. Fixes that apply to both - the DooD host-path resolution, the backgrounded exec so
# traps fire, the capability drop - are worth porting by hand in both directions.

# Names this run's resources (per-run, never fixed: a fixed name lets one run's cleanup kill another's live sandbox) and pre-creates claude-output/.
name_triage_resources() {
  local RUN_TAG="${GITHUB_RUN_ID:-$$}"
  NET_NAME="triage-internal-$RUN_TAG"
  PROXY_NAME="triage-proxy-$RUN_TAG"
  SANDBOX_NAME="claude-triage-$RUN_TAG"

  mkdir -p claude-output
  # Pre-create both before anything below can fail under `set -e`, so the upload/report steps always find real (if empty) files.
  touch claude-output/claude-output.json claude-output/claude-debug.log
}

# Sandbox and proxy are siblings on the HOST daemon, not children of this job, so a cancelled job does not stop them - clean up on every exit path.
cleanup_triage_sandbox() {
  docker rm -f "$PROXY_NAME" "$SANDBOX_NAME" > /dev/null 2>&1 || true
  docker network rm "$NET_NAME" > /dev/null 2>&1 || true
}

# Resolves the host path backing $PWD (docker -v resolves on the HOST under DooD); empty HOST_OUTPUT_DIR means callers fall back to docker cp.
resolve_triage_output_dir() {
  HOST_OUTPUT_DIR=""
  # By container ID from cgroup, not hostname: this runner sets a custom --hostname unrelated to the real container ID.
  local SELF_ID
  SELF_ID=$(grep -oE '[0-9a-f]{64}' /proc/self/cgroup 2>/dev/null | head -1 || true)
  [ -n "$SELF_ID" ] || SELF_ID="$(hostname)"
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

# Builds the isolated network + egress-restricted proxy + sandbox, copies the cloned repos and triage/ in, installs the CLI.
# Expects NET_NAME/PROXY_NAME/SANDBOX_NAME/HOST_OUTPUT_DIR set, repos under ./repos/<name>, and claude-prompt.txt in $PWD.
setup_triage_sandbox() {
  docker network create --internal "$NET_NAME" > /dev/null
  mkdir -p /tmp/squid-triage
  cat > /tmp/squid-triage/squid.conf << 'EOF'
http_port 3128
acl allowed_dst dstdomain .npmjs.org api.anthropic.com
http_access allow allowed_dst
http_access deny all
EOF
  docker create --name "$PROXY_NAME" --network "$NET_NAME" ubuntu/squid:latest > /dev/null
  # docker cp streams over the API, so it works under DooD regardless of whose filesystem the source is on, unlike -v.
  docker cp /tmp/squid-triage/squid.conf "$PROXY_NAME":/etc/squid/squid.conf
  docker start "$PROXY_NAME" > /dev/null
  docker network connect bridge "$PROXY_NAME"
  # Wait for squid to actually accept connections: the npm install below is the first thing through
  # the proxy and fails outright if it is not listening. /dev/tcp needs bash - the image's sh is dash.
  local WAITED=0
  if docker exec "$PROXY_NAME" bash -c 'true' 2>/dev/null; then
    until docker exec "$PROXY_NAME" bash -c 'exec 3<>/dev/tcp/127.0.0.1/3128' 2>/dev/null; do
      WAITED=$((WAITED + 1))
      if [ "$WAITED" -ge 30 ]; then
        echo "::warning::Egress proxy still not listening on :3128 after ${WAITED}s - continuing anyway"
        break
      fi
      sleep 1
    done
    [ "$WAITED" -lt 30 ] && echo "Egress proxy ready after ${WAITED}s"
  else
    echo "::warning::No bash in the proxy image to probe :3128 with - falling back to a fixed wait"
    sleep 2
  fi

  # /output is the ONLY bind mount (when resolved) - a dedicated empty dir, never the job's workspace.
  local OUTPUT_MOUNT_ARGS=()
  [ -n "$HOST_OUTPUT_DIR" ] && OUTPUT_MOUNT_ARGS=(-v "$HOST_OUTPUT_DIR:/output")
  # Triage is untrusted-input processing by definition (the bug report is written by anyone who can
  # file a bug), so drop the default capability set and keep only what the chown/npm work needs.
  local HARDENING_ARGS=(
    --cap-drop=ALL
    --cap-add=CHOWN --cap-add=FOWNER --cap-add=DAC_OVERRIDE
    --security-opt=no-new-privileges
    --pids-limit="${SANDBOX_PIDS_LIMIT:-1024}"
  )
  [ -n "${SANDBOX_MEMORY:-}" ] && HARDENING_ARGS+=(--memory="$SANDBOX_MEMORY")

  docker run -d --name "$SANDBOX_NAME" --network "$NET_NAME" \
    "${OUTPUT_MOUNT_ARGS[@]}" \
    "${HARDENING_ARGS[@]}" \
    -e ANTHROPIC_API_KEY \
    -e CLAUDE_CODE_VERSION \
    -e CLAUDE_MODEL \
    -e CLAUDE_EFFORT \
    -e CLAUDE_MAX_BUDGET_USD \
    -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    -e "HTTP_PROXY=http://$PROXY_NAME:3128" \
    -e "HTTPS_PROXY=http://$PROXY_NAME:3128" \
    -e "http_proxy=http://$PROXY_NAME:3128" \
    -e "https_proxy=http://$PROXY_NAME:3128" \
    -e NO_PROXY=localhost,127.0.0.1 \
    -w /workspace \
    node:24 sleep infinity > /dev/null

  docker exec "$SANDBOX_NAME" mkdir -p /workspace /output
  # Each selected repository lands as its own directory under /workspace, matching the names
  # TRIAGE.md lists in <repositories> so the model's `repository` field is directly usable.
  local REPO_PATH REPO_NAME
  for REPO_PATH in repos/*; do
    [ -d "$REPO_PATH" ] || continue
    REPO_NAME=$(basename "$REPO_PATH")
    docker cp "$REPO_PATH" "$SANDBOX_NAME":/workspace/
    echo "Copied $REPO_NAME into the sandbox"
  done
  docker cp claude-prompt.txt "$SANDBOX_NAME":/workspace/claude-prompt.txt
  # TRIAGE.md references /triage/triage-schema.json, and run_claude_triage reads the schema from there.
  docker cp triage/. "$SANDBOX_NAME":/triage/
  echo "Files inside container: $(docker exec "$SANDBOX_NAME" sh -c 'find /workspace -type f | wc -l')"

  docker exec "$SANDBOX_NAME" npm install -g --no-fund --no-audit --no-update-notifier --loglevel=error "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION:-latest}"
  docker exec "$SANDBOX_NAME" sh -c 'echo "Running triage with model: $CLAUDE_MODEL, effort: $CLAUDE_EFFORT (claude-code $(claude --version || echo unknown))"'
  # --dangerously-skip-permissions refuses to run as root, and docker cp leaves files root-owned.
  docker exec "$SANDBOX_NAME" chown -R node:node /workspace /output
  echo '{"projects":{"/workspace":{"hasTrustDialogAccepted":true}}}' > /tmp/claude-trust-triage.json
  docker cp /tmp/claude-trust-triage.json "$SANDBOX_NAME":/home/node/.claude.json
  docker exec "$SANDBOX_NAME" chown node:node /home/node/.claude.json
}

# Runs claude -p unprivileged, pulls /output out, validates the envelope; returns non-zero (after an ::error::) on failure.
run_claude_triage() {
  local rc=0
  # --disallowedTools Task: a spawned subagent starts with a fresh context instead of reusing the
  # cheap cached one, which trades money for wall-clock (see review-sandbox.sh for the measured case).
  docker exec --user node -w /workspace "$SANDBOX_NAME" bash -c '
    set -euo pipefail
    claude -p --model "$CLAUDE_MODEL" --effort "$CLAUDE_EFFORT" --max-budget-usd "$CLAUDE_MAX_BUDGET_USD" \
      --debug-file /output/claude-debug.log --output-format json --dangerously-skip-permissions \
      --disallowedTools "Task" \
      --json-schema "$(cat /triage/triage-schema.json)" \
      < claude-prompt.txt > /output/claude-output.json
  ' &
  local TRIAGE_PID=$!
  # Backgrounded + waited on, not foreground: POSIX defers trap delivery until the current
  # foreground command exits, so a cancelled job would otherwise keep the container running.
  trap 'docker stop -t 5 "$SANDBOX_NAME" > /dev/null 2>&1 || true' TERM INT
  wait "$TRIAGE_PID" || rc=$?
  trap - TERM INT
  if [ -z "$HOST_OUTPUT_DIR" ]; then
    docker cp "$SANDBOX_NAME":/output/claude-output.json ./claude-output/claude-output.json 2>/dev/null || true
    docker cp "$SANDBOX_NAME":/output/claude-debug.log ./claude-output/claude-debug.log 2>/dev/null || true
  fi
  [ -s claude-output/claude-output.json ] || echo '{}' > claude-output/claude-output.json

  if [ "$rc" -ne 0 ] || ! jq -e '.is_error == false and ((.result // "") | length > 0)' claude-output/claude-output.json > /dev/null 2>&1; then
    local subtype oom
    subtype=$(jq -r '.subtype // "unknown"' claude-output/claude-output.json 2>/dev/null || echo "unparsable")
    oom=$(docker inspect "$SANDBOX_NAME" --format '{{.State.OOMKilled}}' 2>/dev/null || echo "unknown")
    echo "::error::Triage failed (exit $rc, subtype: $subtype, OOMKilled: $oom)"
    echo "Result excerpt: $(jq -r '.result // empty' claude-output/claude-output.json 2>/dev/null | head -c 300 || true)"
    return 1
  fi
}

# Extracts+validates the model's JSON into claude-structured.json (best-effort - the report step has a fallback) and echoes one summary line.
summarize_claude_triage() {
  jq -r '.result' claude-output/claude-output.json \
    | EXTRACT_JSON_SCHEMA=triage/triage-schema.json python3 .gitea/scripts/extract-json.py > claude-structured.json || {
    echo "::warning::Could not extract a valid triage JSON from the model's response - reporting fallback"
    echo "Result tail: $(jq -r '.result // empty' claude-output/claude-output.json 2>/dev/null | tail -c 500 || true)"
  }
  local STATS LOCATIONS CONFIDENCE COST USAGE
  STATS=$(jq -r '"\(.num_turns // "?") turns / \((.duration_ms // 0) / 1000 | round)s"' claude-output/claude-output.json)
  LOCATIONS=$([ -s claude-structured.json ] && jq '.locations | length' claude-structured.json 2>/dev/null || echo '?')
  CONFIDENCE=$([ -s claude-structured.json ] && jq -r '.summary.confidence // "?"' claude-structured.json 2>/dev/null || echo '?')
  COST=$(jq -r '.total_cost_usd // 0 | (. * 1000 | round) / 1000' claude-output/claude-output.json)
  USAGE=$(jq -r '.modelUsage // {} | to_entries | map("\(.key): \(.value.inputTokens // 0)in/\(.value.outputTokens // 0)out") | join(", ")' claude-output/claude-output.json 2>/dev/null || echo "n/a")
  echo "Triage OK: $STATS, $LOCATIONS location(s), confidence $CONFIDENCE, \$$COST ($USAGE)"
}
