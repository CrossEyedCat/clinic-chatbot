#!/usr/bin/env bash
# run_local.sh - one-command local launch of the BrightCare clinic bot
# (Linux / macOS / GitHub Codespaces)
#
#   ./run_local.sh            start everything (installs/trains on first run)
#   ./run_local.sh stop       stop all three servers
#   ./run_local.sh retrain    force retrain, then start
#
# Ports: 5005 Rasa API | 5055 action server | 8088 web chat
set -euo pipefail
cd "$(dirname "$0")"

RASA_PORT=${RASA_PORT:-5005}
ACTION_PORT=${ACTION_PORT:-5055}
WEB_PORT=${WEB_PORT:-8088}
VENV_DIR=${VENV_DIR:-.venv-rasa}
PID_FILE=.run_local_pids
LOG_DIR=.logs

free_ports() {
  for port in "$RASA_PORT" "$ACTION_PORT" "$WEB_PORT"; do
    if command -v lsof >/dev/null 2>&1; then
      pids=$(lsof -ti tcp:"$port" 2>/dev/null || true)
    else
      pids=$(fuser "$port"/tcp 2>/dev/null || true)
    fi
    if [ -n "${pids:-}" ]; then
      echo "  freeing port $port (PID $pids)"
      kill -9 $pids 2>/dev/null || true
    fi
  done
}

if [ "${1:-}" = "stop" ]; then
  if [ -f "$PID_FILE" ]; then
    xargs -r kill < "$PID_FILE" 2>/dev/null || true
    rm -f "$PID_FILE"
  fi
  free_ports
  echo "All bot processes stopped."
  exit 0
fi

# ---------------------------------------------------------------- find python
PY=""
for cand in python3.10 python3.9 python3.8 python3 python; do
  if command -v "$cand" >/dev/null 2>&1; then
    v=$("$cand" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)
    case "$v" in 3.8|3.9|3.10) PY="$cand"; break;; esac
  fi
done
if [ -z "$PY" ]; then
  echo "ERROR: no Python 3.8-3.10 found (Rasa 3.6 requirement)." >&2
  exit 1
fi
echo "Using Python: $PY ($($PY --version 2>&1))"

# ---------------------------------------------------------------- venv + rasa
if [ ! -x "$VENV_DIR/bin/python" ]; then
  echo "Creating virtual environment at $VENV_DIR ..."
  "$PY" -m venv "$VENV_DIR"
fi
VENV_PY="$VENV_DIR/bin/python"
RASA="$VENV_DIR/bin/rasa"

if ! "$VENV_PY" -c "import rasa" >/dev/null 2>&1; then
  echo "Installing Rasa 3.6.21 (5-10 minutes on first run) ..."
  "$VENV_PY" -m pip install --upgrade pip
  "$VENV_PY" -m pip install "rasa==3.6.21"
fi

# ---------------------------------------------------------------- train model
need_train=0
[ "${1:-}" = "retrain" ] && need_train=1
newest_model=$(ls -t models/*.tar.gz 2>/dev/null | head -1 || true)
if [ -z "$newest_model" ]; then
  need_train=1
else
  newest_data=$(ls -t data/*.yml config.yml domain.yml | head -1)
  if [ "$newest_data" -nt "$newest_model" ]; then
    echo "Training data changed after the last model - retraining."
    need_train=1
  fi
fi
if [ "$need_train" = 1 ]; then
  echo "Training the model (a few minutes) ..."
  "$RASA" train
else
  echo "Model found and up to date - skipping training (./run_local.sh retrain to force)."
fi

# ---------------------------------------------------------------- start servers
echo "Freeing ports $RASA_PORT/$ACTION_PORT/$WEB_PORT if busy ..."
free_ports
mkdir -p "$LOG_DIR"
: > "$PID_FILE"

echo "Starting action server on :$ACTION_PORT ..."
"$RASA" run actions --port "$ACTION_PORT" >"$LOG_DIR/actions.log" 2>&1 &
echo $! >> "$PID_FILE"

echo "Starting Rasa API on :$RASA_PORT ..."
"$RASA" run --enable-api --cors '*' --port "$RASA_PORT" --endpoints endpoints.yml >"$LOG_DIR/rasa.log" 2>&1 &
echo $! >> "$PID_FILE"

echo "Starting web chat on :$WEB_PORT ..."
"$VENV_PY" -m http.server "$WEB_PORT" --directory webchat >"$LOG_DIR/web.log" 2>&1 &
echo $! >> "$PID_FILE"

# ---------------------------------------------------------------- wait + report
echo "Waiting for the Rasa server (model loading takes ~30-60 s) ..."
up=0
for _ in $(seq 1 60); do
  sleep 2
  if curl -sf "http://localhost:$RASA_PORT/status" >/dev/null 2>&1 \
     && curl -sf "http://localhost:$ACTION_PORT/health" >/dev/null 2>&1; then
    up=1; break
  fi
done

if [ "$up" = 1 ]; then
  echo
  echo "=============================================================="
  echo "  Bot is up!"
  echo "  Rasa API:      http://localhost:$RASA_PORT/status"
  echo "  Action server: http://localhost:$ACTION_PORT/health"
  echo "  Web chat:      http://localhost:$WEB_PORT"
  echo "  Logs:          $LOG_DIR/"
  echo "  Stop with:     ./run_local.sh stop"
  echo "=============================================================="
  echo "In GitHub Codespaces: make port $RASA_PORT Public in the Ports tab,"
  echo "then open the chat with ?rasa=<public URL of port $RASA_PORT>."
else
  echo "ERROR: servers did not come up in 2 minutes - see $LOG_DIR/rasa.log" >&2
  exit 1
fi
