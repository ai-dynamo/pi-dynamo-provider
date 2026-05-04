#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/run-dynamo-single-gpu.sh [OPTIONS] [-- SGLANG_ARGS...]

Clone/build Dynamo from the mooncake replay branch, create a uv venv, install
Dynamo into it, and launch a single-GPU agent-capable SGLang worker plus Dynamo
frontend with agent tracing and Pi tool relay enabled.

Options:
  --workdir PATH              Cache/work directory.
                              Default: ${XDG_CACHE_HOME:-$HOME/.cache}/pi-dynamo-provider
  --dynamo-dir PATH           Dynamo checkout path. Default: <workdir>/dynamo
  --dynamo-repo URL           Dynamo git repo. Default: https://github.com/ai-dynamo/dynamo.git
  --dynamo-ref REF            Dynamo branch/ref. Default: ishan/mooncake-replay-hashes
  --model MODEL               Served model. Default: zai-org/GLM-4.7-Flash
  --gpu GPU                   Single GPU id exposed to the worker. Default: 0
  --http-port PORT            Dynamo HTTP port. Default: 18083
  --system-port PORT          Worker system metrics/control port. Default: 18084
  --tool-events-endpoint END  ZMQ endpoint for Pi tool events. Default: tcp://127.0.0.1:20390
  --skip-build                Reuse the existing Dynamo venv/install.
  -h, --help                  Show this help.

Environment overrides:
  PI_DYNAMO_WORKDIR
  DYNAMO_DIR
  DYNAMO_REPO
  DYNAMO_REF
  MODEL
  CUDA_VISIBLE_DEVICES
  DYN_HTTP_PORT
  DYN_SYSTEM_PORT
  DYN_AGENT_TRACE_TOOL_EVENTS_ZMQ_ENDPOINT
  DYN_AGENT_TRACE_OUTPUT_PATH
  NATS_SERVER

Examples:
  scripts/run-dynamo-single-gpu.sh
  scripts/run-dynamo-single-gpu.sh --gpu 1 --http-port 18083
  scripts/run-dynamo-single-gpu.sh --model Qwen/Qwen3-0.6B -- --disable-cuda-graph
EOF
}

log() {
    printf '[pi-dynamo] %s\n' "$*"
}

die() {
    printf '[pi-dynamo] ERROR: %s\n' "$*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

tcp_open() {
    local host="$1"
    local port="$2"
    timeout 1 bash -c "</dev/tcp/${host}/${port}" >/dev/null 2>&1
}

cleanup() {
    local rc=$?
    if ((${#CHILD_PIDS[@]} > 0)); then
        log "Cleaning up launched processes..."
        for pid in "${CHILD_PIDS[@]}"; do
            kill "$pid" >/dev/null 2>&1 || true
        done
        wait >/dev/null 2>&1 || true
    fi
    exit "$rc"
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_WORKDIR="${XDG_CACHE_HOME:-$HOME/.cache}/pi-dynamo-provider"

WORKDIR="${PI_DYNAMO_WORKDIR:-$DEFAULT_WORKDIR}"
DYNAMO_DIR="${DYNAMO_DIR:-}"
DYNAMO_REPO="${DYNAMO_REPO:-https://github.com/ai-dynamo/dynamo.git}"
DYNAMO_REF="${DYNAMO_REF:-ishan/mooncake-replay-hashes}"
MODEL="${MODEL:-zai-org/GLM-4.7-Flash}"
GPU="${CUDA_VISIBLE_DEVICES:-0}"
HTTP_PORT="${DYN_HTTP_PORT:-18083}"
SYSTEM_PORT="${DYN_SYSTEM_PORT:-18084}"
TOOL_EVENTS_ENDPOINT="${DYN_AGENT_TRACE_TOOL_EVENTS_ZMQ_ENDPOINT:-tcp://127.0.0.1:20390}"
SKIP_BUILD=0
SGLANG_ARGS=()

while (($# > 0)); do
    case "$1" in
        --workdir)
            WORKDIR="$2"
            shift 2
            ;;
        --dynamo-dir)
            DYNAMO_DIR="$2"
            shift 2
            ;;
        --dynamo-repo)
            DYNAMO_REPO="$2"
            shift 2
            ;;
        --dynamo-ref)
            DYNAMO_REF="$2"
            shift 2
            ;;
        --model|--model-path)
            MODEL="$2"
            shift 2
            ;;
        --gpu)
            GPU="$2"
            shift 2
            ;;
        --http-port)
            HTTP_PORT="$2"
            shift 2
            ;;
        --system-port)
            SYSTEM_PORT="$2"
            shift 2
            ;;
        --tool-events-endpoint)
            TOOL_EVENTS_ENDPOINT="$2"
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
        --)
            shift
            SGLANG_ARGS+=("$@")
            break
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

DYNAMO_DIR="${DYNAMO_DIR:-$WORKDIR/dynamo}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$WORKDIR/runs/$RUN_ID"
LOG_DIR="$RUN_DIR/logs"
TRACE_PATH="${DYN_AGENT_TRACE_OUTPUT_PATH:-$RUN_DIR/dynamo-agent-trace.jsonl}"
FILE_KV="${DYN_FILE_KV:-$RUN_DIR/file-kv}"
NATS_SERVER="${NATS_SERVER:-nats://127.0.0.1:4222}"
CHILD_PIDS=()

if [[ "$GPU" == *,* ]]; then
    die "this launcher expects exactly one GPU, got '$GPU'. Use --gpu 0 here, or use Dynamo's upstream multi-GPU launch scripts."
fi

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require_cmd git
require_cmd uv
require_cmd python3
require_cmd curl
require_cmd timeout

mkdir -p "$WORKDIR" "$RUN_DIR" "$LOG_DIR" "$(dirname "$TRACE_PATH")" "$FILE_KV"

clone_or_update_dynamo() {
    if [[ ! -d "$DYNAMO_DIR/.git" ]]; then
        log "Cloning Dynamo into $DYNAMO_DIR"
        git clone "$DYNAMO_REPO" "$DYNAMO_DIR"
    fi

    cd "$DYNAMO_DIR"

    if ! git diff --quiet || ! git diff --cached --quiet; then
        die "Dynamo checkout has local changes: $DYNAMO_DIR. Commit/stash them or use --dynamo-dir with a clean checkout."
    fi

    log "Fetching Dynamo ref $DYNAMO_REF"
    git fetch origin "$DYNAMO_REF"
    git checkout --detach FETCH_HEAD
}

build_dynamo() {
    cd "$DYNAMO_DIR"
    log "Creating uv venv at $DYNAMO_DIR/.venv"
    uv venv .venv
    # shellcheck disable=SC1091
    source .venv/bin/activate

    log "Installing build tools"
    uv pip install -U pip maturin

    log "Building Dynamo Python bindings"
    (cd lib/bindings/python && maturin develop --uv)

    log "Installing Dynamo package"
    uv pip install -e .
}

ensure_nats() {
    case "$NATS_SERVER" in
        nats://127.0.0.1:4222|nats://localhost:4222)
            if tcp_open 127.0.0.1 4222; then
                log "Using existing NATS server at $NATS_SERVER"
                return
            fi

            if ! command -v nats-server >/dev/null 2>&1; then
                die "NATS is not running on 127.0.0.1:4222 and nats-server is not installed. Start NATS or set NATS_SERVER."
            fi

            log "Starting local NATS server at $NATS_SERVER"
            nats-server -p 4222 >"$LOG_DIR/nats.log" 2>&1 &
            CHILD_PIDS+=("$!")
            sleep 1
            tcp_open 127.0.0.1 4222 || die "nats-server did not open port 4222; see $LOG_DIR/nats.log"
            ;;
        *)
            log "Using external NATS server at $NATS_SERVER"
            ;;
    esac
}

print_ready_block() {
    cat <<EOF

Dynamo is ready.

Pi environment for another shell:

  export DYNAMO_BASE_URL=http://127.0.0.1:${HTTP_PORT}/v1
  export DYNAMO_API_KEY=dummy
  export DYN_AGENT_WORKFLOW_TYPE_ID=pi_coding_agent
  export DYN_AGENT_WORKFLOW_ID=pi-demo-${RUN_ID}
  export DYN_AGENT_TOOL_EVENTS_ZMQ_ENDPOINT=${TOOL_EVENTS_ENDPOINT}

Example Pi command:

  pi --model dynamo/${MODEL} -p "Reply exactly ok."

Trace output:

  ${TRACE_PATH}

Perfetto conversion:

  cd ${DYNAMO_DIR}
  source .venv/bin/activate
  python benchmarks/agent_trace/convert_to_perfetto.py \\
    ${TRACE_PATH} \\
    --include-markers \\
    --separate-stage-tracks \\
    --output ${RUN_DIR}/dynamo-agent-trace.perfetto.json

EOF
}

wait_for_model() {
    local url="http://127.0.0.1:${HTTP_PORT}/v1/models"
    local deadline=$((SECONDS + 900))
    log "Waiting for $url to expose models..."

    while ((SECONDS < deadline)); do
        if models_json="$(curl -sf --max-time 2 "$url" 2>/dev/null)"; then
            if grep -Fq "\"id\":\"${MODEL}\"" <<<"$models_json" || grep -Fq "\"id\": \"${MODEL}\"" <<<"$models_json"; then
                print_ready_block
                return
            fi
            log "Dynamo responded, but ${MODEL} is not listed yet."
        fi

        for pid in "${CHILD_PIDS[@]}"; do
            kill -0 "$pid" >/dev/null 2>&1 || die "a launched process exited before the model became ready; see $LOG_DIR"
        done
        sleep 5
    done

    die "timed out waiting for model readiness at $url"
}

launch_dynamo() {
    cd "$DYNAMO_DIR"
    # shellcheck disable=SC1091
    source .venv/bin/activate

    export CUDA_VISIBLE_DEVICES="$GPU"
    export DYN_HTTP_PORT="$HTTP_PORT"
    export DYN_DISCOVERY_BACKEND="${DYN_DISCOVERY_BACKEND:-file}"
    export DYN_FILE_KV="$FILE_KV"
    export DYN_EVENT_PLANE="${DYN_EVENT_PLANE:-nats}"
    export NATS_SERVER
    export DYN_AGENT_TRACE_SINKS="${DYN_AGENT_TRACE_SINKS:-jsonl}"
    export DYN_AGENT_TRACE_OUTPUT_PATH="$TRACE_PATH"
    export DYN_AGENT_TRACE_JSONL_FLUSH_INTERVAL_MS="${DYN_AGENT_TRACE_JSONL_FLUSH_INTERVAL_MS:-100}"
    export DYN_AGENT_TRACE_TOOL_EVENTS_ZMQ_ENDPOINT="$TOOL_EVENTS_ENDPOINT"
    export DYN_LOG="${DYN_LOG:-info}"

    log "Run directory: $RUN_DIR"
    log "Dynamo checkout: $DYNAMO_DIR"
    log "Model: $MODEL"
    log "Single GPU: CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"
    log "HTTP: http://127.0.0.1:$HTTP_PORT/v1"
    log "Trace JSONL: $TRACE_PATH"
    log "Tool relay endpoint: $TOOL_EVENTS_ENDPOINT"

    log "Starting Dynamo frontend"
    python3 -m dynamo.frontend \
        --router-mode kv \
        --router-reset-states \
        >"$LOG_DIR/frontend.log" 2>&1 &
    CHILD_PIDS+=("$!")

    log "Starting single-GPU Dynamo SGLang worker"
    DYN_SYSTEM_PORT="$SYSTEM_PORT" \
    python3 -m dynamo.sglang \
        --model-path "$MODEL" \
        --served-model-name "$MODEL" \
        --page-size 16 \
        --tp 1 \
        --trust-remote-code \
        --enable-streaming-session \
        --skip-tokenizer-init \
        --dyn-reasoning-parser glm45 \
        --dyn-tool-call-parser glm47 \
        --kv-events-config '{"publisher":"zmq","topic":"kv-events","endpoint":"tcp://*:5557"}' \
        --enable-metrics \
        "${SGLANG_ARGS[@]}" \
        >"$LOG_DIR/worker.log" 2>&1 &
    CHILD_PIDS+=("$!")
}

clone_or_update_dynamo

if ((SKIP_BUILD == 0)); then
    build_dynamo
else
    [[ -x "$DYNAMO_DIR/.venv/bin/python" ]] || die "--skip-build requested, but $DYNAMO_DIR/.venv is missing"
    log "Skipping Dynamo build/install"
fi

ensure_nats
launch_dynamo
wait_for_model

log "Dynamo is running. Press Ctrl+C to stop."
wait -n "${CHILD_PIDS[@]}"
