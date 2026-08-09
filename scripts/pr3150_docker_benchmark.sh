#!/usr/bin/env bash
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
CONTROL_DIR="$ROOT/control"
IMPROVED_DIR="$ROOT/improved"
RESULTS_DIR="$CONTROL_DIR/results"
COMPOSE_OVERRIDE="$CONTROL_DIR/scripts/pr3150_docker_benchmark.compose.yml"
COMPOSE_PROJECT_NAME="woc-pr3150-bench"

export POSTGRES_PASSWORD="benchmark-only-not-production"
export NODE_OPTIONS="--max-old-space-size=4096"
export MAX_PLAYERS_PER_REALM="200"
export BENCH_IMAGE="woc-live:7e8c2c3"
export BENCH_VERSION="cleanup"

compose() {
  docker compose \
    --project-name "$COMPOSE_PROJECT_NAME" \
    --file "$IMPROVED_DIR/docker-compose.yml" \
    --file "$COMPOSE_OVERRIDE" \
    "$@"
}

cleanup_stack() {
  compose down --volumes --remove-orphans --timeout 30 || true
}

wait_for_game() {
  local deadline=$((SECONDS + 180))
  while (( SECONDS < deadline )); do
    if [[ "$(docker inspect --format '{{.State.Health.Status}}' eastbrook-game 2>/dev/null || true)" == "healthy" ]] && \
      curl --fail --silent --show-error http://127.0.0.1:8787/api/status | jq -e '.ok == true and .dev_commands == true' >/dev/null; then
      return 0
    fi
    sleep 2
  done
  echo "game server did not become benchmark-ready" >&2
  compose ps >&2 || true
  compose logs --tail 300 game postgres >&2 || true
  return 1
}

collect_stats() {
  local output="$1"
  printf 'timestamp,cpu_percent,memory_usage,memory_percent,net_io,block_io\n' > "$output"
  while docker inspect eastbrook-game >/dev/null 2>&1; do
    local row
    row="$(docker stats --no-stream --format '{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}},{{.NetIO}},{{.BlockIO}}' eastbrook-game 2>/dev/null || true)"
    if [[ -n "$row" ]]; then
      printf '%s,%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$row" >> "$output"
    fi
    sleep 5
  done
}

run_trial() {
  local label="$1"
  local image="$2"
  local version="$3"
  local trial="$4"
  local scratch="/tmp/woc-pr3150-${label}-${trial}"
  local json="$RESULTS_DIR/${label}-${trial}.json"
  local stats="$RESULTS_DIR/${label}-${trial}.stats.csv"
  local server_log="$RESULTS_DIR/${label}-${trial}.server.log"

  echo "===== ${label} trial ${trial} ====="
  cleanup_stack
  rm -rf "$scratch"
  mkdir -p "$scratch/media" "$scratch/sfx" "$scratch/parse"
  chmod 0777 "$scratch/media" "$scratch/parse"
  chmod 0755 "$scratch/sfx"

  export BENCH_IMAGE="$image"
  export BENCH_VERSION="$version"
  export EASTBROOK_MEDIA_DIR="$scratch/media"
  export EASTBROOK_SFX_DIR="$scratch/sfx"
  export PARSE_SPOOL_HOST_DIR="$scratch/parse"

  compose up --detach --no-build postgres game
  wait_for_game
  sleep 20

  collect_stats "$stats" &
  local stats_pid=$!
  local load_rc=0
  docker run --rm --network host \
    --volume "$RESULTS_DIR:/results" \
    --env SERVER_URL=http://127.0.0.1:8787 \
    --env BOTS=60 \
    --env DURATION_MS=90000 \
    --env LEVEL=12 \
    --env CLUSTER_X=-2 \
    --env CLUSTER_Z=70 \
    --env CLUSTER_R=12 \
    --env RAMP_MS=40 \
    --env OBSERVER=1 \
    --env JSON_OUT="/results/${label}-${trial}.json" \
    woc-bench-harness:5b38c5a \
    node scripts/server_load_jitter.mjs || load_rc=$?

  kill "$stats_pid" 2>/dev/null || true
  wait "$stats_pid" 2>/dev/null || true
  compose logs --no-color game > "$server_log" 2>&1 || true

  if (( load_rc != 0 )); then
    echo "${label} trial ${trial} failed with exit code ${load_rc}" >&2
    tail -n 300 "$server_log" >&2 || true
    cleanup_stack
    return "$load_rc"
  fi
  test -s "$json"
  cleanup_stack
}

trap cleanup_stack EXIT
mkdir -p "$RESULTS_DIR"

run_trial live woc-live:7e8c2c3 7e8c2c3cd8136242a2d8ff29c376dd2bef66f849 1
run_trial improved woc-improved:5b38c5a 5b38c5aa088c1aa5341cc6c17b45b03a2afc7a47 1
run_trial live woc-live:7e8c2c3 7e8c2c3cd8136242a2d8ff29c376dd2bef66f849 2
run_trial improved woc-improved:5b38c5a 5b38c5aa088c1aa5341cc6c17b45b03a2afc7a47 2
run_trial live woc-live:7e8c2c3 7e8c2c3cd8136242a2d8ff29c376dd2bef66f849 3
run_trial improved woc-improved:5b38c5a 5b38c5aa088c1aa5341cc6c17b45b03a2afc7a47 3

trap - EXIT
cleanup_stack
