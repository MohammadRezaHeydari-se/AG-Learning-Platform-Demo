#!/bin/sh
#
# start.sh - one-command launcher for the AG Learning Platform Demo (Linux/macOS).
#
# It walks through a numbered checklist of setup stages and shows a progress bar
# based on how many stages have actually completed (never a fake timer):
#
#   [1/9] [OK]      Docker CLI detected
#   [2/9] [OK]      Docker Engine is running
#   ...
#   Setup steps completed  [####################]  100%
#
# Stages: Docker CLI, Docker Engine, Compose v2, existing container/image,
# port selection, image build (+ Python dependencies), container startup,
# Django migration/seeding readiness, HTTP readiness, then the final URL.
#
# Safety: read-only checks; the launcher never installs software, never deletes
# volumes/databases, preserves changed demo passwords and any running container,
# and never uses eval. Ctrl+C stops the launcher without removing anything.
#
# Usage:
#   ./start.sh                 # auto port (prefers 8000), then reuse or build
#   HOST_PORT=9000 ./start.sh  # explicit host port
#   NO_COLOR=1 ./start.sh      # plain output (also honours the NO_COLOR env var)
#   ./start.sh --self-test     # run internal logic checks and exit
#   ./start.sh --help

set -eu

# ---------------------------------------------------------------------------
# Paths and constants
# ---------------------------------------------------------------------------
SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

DOCKER_INSTALL_URL="https://docs.docker.com/get-docker/"
COMPOSE_INSTALL_URL="https://docs.docker.com/compose/install/"

SERVICE="web"
CONTAINER_PORT="8000"
PORT_SCAN_MAX="8050"
READINESS_TIMEOUT="${READINESS_TIMEOUT:-90}"
READINESS_INTERVAL="${READINESS_INTERVAL:-2}"

TOTAL_STEPS=9
BAR_WIDTH=20
PROGRESS_LABEL="Setup steps completed"

# Runtime state.
COMPLETED=0
TRANSIENT_LEN=0
BAR_ACTIVE=0
INTERACTIVE=0
USE_COLOR=0
CONTAINER_RUNNING=0
IMAGE_EXISTS=0
REUSED_PORT=""
CHOSEN_PORT=""

# ---------------------------------------------------------------------------
# Display: colours only on an interactive terminal, never with NO_COLOR/dumb.
# ---------------------------------------------------------------------------
init_display() {
  if [ -t 1 ]; then
    INTERACTIVE=1
  fi
  if [ "$INTERACTIVE" = 1 ] && [ -z "${NO_COLOR+x}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    USE_COLOR=1
  fi
  _esc=$(printf '\033')
  if [ "$USE_COLOR" = 1 ]; then
    c_reset="${_esc}[0m"
    c_dim="${_esc}[2m"
    c_green="${_esc}[32m"
    c_yellow="${_esc}[33m"
    c_red="${_esc}[31m"
    c_cyan="${_esc}[36m"
  else
    c_reset=''
    c_dim=''
    c_green=''
    c_yellow=''
    c_red=''
    c_cyan=''
  fi
}

spaces() {
  _sp_n=$1
  _sp_i=0
  while [ "$_sp_i" -lt "$_sp_n" ]; do
    printf ' '
    _sp_i=$((_sp_i + 1))
  done
}

clear_transient() {
  if [ "$TRANSIENT_LEN" -gt 0 ] && [ "$INTERACTIVE" = 1 ]; then
    printf '\r'
    spaces "$TRANSIENT_LEN"
    printf '\r'
  fi
  TRANSIENT_LEN=0
}

# Pure progress maths: percentage and bar are derived from completed checkpoints.
percent_for() {
  _c=$1
  [ "$_c" -gt "$TOTAL_STEPS" ] && _c=$TOTAL_STEPS
  printf '%s' "$(( _c * 100 / TOTAL_STEPS ))"
}

bar_for() {
  _bf_c=$1
  [ "$_bf_c" -gt "$TOTAL_STEPS" ] && _bf_c=$TOTAL_STEPS
  _bf_filled=$(( _bf_c * BAR_WIDTH / TOTAL_STEPS ))
  _bf_empty=$(( BAR_WIDTH - _bf_filled ))
  _bf_i=0
  while [ "$_bf_i" -lt "$_bf_filled" ]; do
    printf '#'
    _bf_i=$((_bf_i + 1))
  done
  _bf_i=0
  while [ "$_bf_i" -lt "$_bf_empty" ]; do
    printf '-'
    _bf_i=$((_bf_i + 1))
  done
}

draw_progress() {
  _pct=$(percent_for "$COMPLETED")
  _bar=$(bar_for "$COMPLETED")
  _plain="${PROGRESS_LABEL}  [${_bar}]  ${_pct}%"
  if [ "$INTERACTIVE" = 1 ]; then
    clear_transient
    if [ "$USE_COLOR" = 1 ]; then
      printf '\r%s%s%s' "$c_dim" "$_plain" "$c_reset"
    else
      printf '\r%s' "$_plain"
    fi
    TRANSIENT_LEN=${#_plain}
  else
    printf '%s\n' "$_plain"
  fi
  BAR_ACTIVE=1
}

finalize_progress() {
  if [ "$INTERACTIVE" = 1 ] && [ "$TRANSIENT_LEN" -gt 0 ]; then
    printf '\n'
  fi
  TRANSIENT_LEN=0
}

status_tag() {
  case "$1" in
    OK)
      _p='[OK]'
      _c=$c_green
      ;;
    RUNNING)
      _p='[RUNNING]'
      _c=$c_cyan
      ;;
    SKIP)
      _p='[SKIP]'
      _c=$c_yellow
      ;;
    ERROR)
      _p='[ERROR]'
      _c=$c_red
      ;;
    *)
      _p="[$1]"
      _c=''
      ;;
  esac
  while [ ${#_p} -lt 9 ]; do
    _p="$_p "
  done
  if [ "$USE_COLOR" = 1 ]; then
    printf '%s%s%s' "$_c" "$_p" "$c_reset"
  else
    printf '%s' "$_p"
  fi
}

step_line() {
  _n=$1
  _status=$2
  _msg=$3
  clear_transient
  _tag=$(status_tag "$_status")
  if [ "$USE_COLOR" = 1 ]; then
    printf '%s[%s/%s]%s %s %s\n' "$c_dim" "$_n" "$TOTAL_STEPS" "$c_reset" "$_tag" "$_msg"
  else
    printf '[%s/%s] %s %s\n' "$_n" "$TOTAL_STEPS" "$_tag" "$_msg"
  fi
}

begin_step() {
  step_line "$1" RUNNING "$2"
}

finish_step() {
  step_line "$1" "$2" "$3"
  COMPLETED=$((COMPLETED + 1))
  draw_progress
}

say() {
  clear_transient
  printf '%s\n' "$*"
  if [ "$INTERACTIVE" = 1 ] && [ "$BAR_ACTIVE" = 1 ]; then
    draw_progress
  fi
}

# Mask anything that looks like a secret before showing logs.
# Case classes are spelled out per letter so this works on GNU and BSD sed.
redact() {
  sed -E 's/([A-Za-z0-9_]*([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn])[A-Za-z0-9_]*)[=:][[:space:]]*[^[:space:]]+/\1=***/g'
}

show_sanitized_logs() {
  _ids=$(docker compose ps -aq "$SERVICE" 2>/dev/null || true)
  [ -n "$_ids" ] || return 0
  printf '\nRecent container logs (sanitized, last 50 lines):\n'
  docker compose logs --tail=50 "$SERVICE" 2>&1 | redact | sed 's/^/  /'
}

die_step() {
  _n=$1
  _name=$2
  _cause=$3
  _next=$4
  step_line "$_n" ERROR "$_name"
  draw_progress
  finalize_progress
  if [ "$USE_COLOR" = 1 ]; then
    printf '\n%sSetup failed%s at step %s of %s: %s\n' "$c_red" "$c_reset" "$_n" "$TOTAL_STEPS" "$_name"
  else
    printf '\nSetup failed at step %s of %s: %s\n' "$_n" "$TOTAL_STEPS" "$_name"
  fi
  printf 'Progress: %s%% (%s of %s setup steps completed)\n' "$(percent_for "$COMPLETED")" "$COMPLETED" "$TOTAL_STEPS"
  printf '\nLikely cause:\n  %s\n' "$_cause"
  printf '\nNext step:\n  %s\n' "$_next"
  show_sanitized_logs
  printf '\nNo containers, volumes or demo data were removed.\n'
  exit 1
}

on_interrupt() {
  clear_transient
  finalize_progress
  printf '\nCancelled (interrupted). No containers, volumes or demo data were removed.\n' >&2
  printf 'If a container was starting, stop it later with: docker compose down\n' >&2
  exit 130
}

# ---------------------------------------------------------------------------
# Port helpers
# ---------------------------------------------------------------------------
is_valid_port() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

port_in_use() {
  _port=$1
  if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import socket, sys
s = socket.socket()
s.settimeout(0.5)
rc = s.connect_ex(("127.0.0.1", int(sys.argv[1])))
s.close()
sys.exit(0 if rc == 0 else 1)' "$_port" >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi
  if command -v nc >/dev/null 2>&1; then
    if nc -z 127.0.0.1 "$_port" >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi
  return 1
}

find_free_port() {
  _candidate=$1
  while [ "$_candidate" -le "$PORT_SCAN_MAX" ]; do
    if ! port_in_use "$_candidate"; then
      printf '%s' "$_candidate"
      return 0
    fi
    _candidate=$((_candidate + 1))
  done
  return 1
}

clean_env_value() {
  printf '%s' "$1" | tr -d '\r' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
          -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

env_file_port() {
  [ -f .env ] || return 1
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      \#*) continue ;;
      HOST_PORT=*)
        _value=$(clean_env_value "${_line#HOST_PORT=}")
        if [ -n "$_value" ]; then
          printf '%s' "$_value"
          return 0
        fi
        ;;
    esac
  done < .env
  return 1
}

# ---------------------------------------------------------------------------
# Docker helpers
# ---------------------------------------------------------------------------
image_exists() {
  _img=$(docker compose config --images 2>/dev/null | head -n 1 || true)
  [ -n "$_img" ] || return 1
  docker image inspect "$_img" >/dev/null 2>&1
}

detect_running_port() {
  _line=$(docker compose port "$SERVICE" "$CONTAINER_PORT" 2>/dev/null || true)
  _port=${_line##*:}
  if is_valid_port "$_port"; then
    printf '%s' "$_port"
    return 0
  fi
  return 1
}

wait_for_seed() {
  _elapsed=0
  while [ "$_elapsed" -lt "$READINESS_TIMEOUT" ]; do
    if docker compose logs "$SERVICE" 2>/dev/null | grep -q 'Demo data ready'; then
      return 0
    fi
    if [ "$_elapsed" -gt 0 ]; then
      _state=$(docker compose ps -a --format '{{.State}}' "$SERVICE" 2>/dev/null || true)
      case "$_state" in
        exited | dead) return 1 ;;
      esac
    fi
    sleep "$READINESS_INTERVAL"
    _elapsed=$((_elapsed + READINESS_INTERVAL))
  done
  return 1
}

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------
http_ready() {
  _url=$1
  if command -v curl >/dev/null 2>&1; then
    if curl -fsS -o /dev/null --max-time 5 "$_url" >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi
  if command -v wget >/dev/null 2>&1; then
    if wget -q -T 5 -O /dev/null "$_url" >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi
  if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import sys, urllib.request
urllib.request.urlopen(sys.argv[1], timeout=5).read(1)' "$_url" >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi
  if docker compose ps --status running -q "$SERVICE" 2>/dev/null | grep -q .; then
    return 0
  fi
  return 1
}

wait_for_http() {
  _url=$1
  _elapsed=0
  while [ "$_elapsed" -lt "$READINESS_TIMEOUT" ]; do
    if http_ready "$_url"; then
      return 0
    fi
    sleep "$READINESS_INTERVAL"
    _elapsed=$((_elapsed + READINESS_INTERVAL))
  done
  return 1
}

# ---------------------------------------------------------------------------
# Stages (each renders one checklist line)
# ---------------------------------------------------------------------------
stage_docker_cli() {
  begin_step 1 "Detecting the Docker CLI..."
  if ! command -v docker >/dev/null 2>&1; then
    die_step 1 "Docker CLI detection" \
      "Docker is not installed on this machine (the 'docker' command was not found)." \
      "Install Docker Desktop (macOS/Windows) or Docker Engine + Compose v2 (Linux) from $DOCKER_INSTALL_URL, then open a new terminal and run this launcher again."
  fi
  finish_step 1 OK "Docker CLI detected (already installed; this launcher never installs software)."
}

stage_engine() {
  begin_step 2 "Checking that the Docker Engine is running..."
  if ! docker info >/dev/null 2>&1; then
    die_step 2 "Docker Engine availability" \
      "Docker is installed but the Docker Engine is not running or not reachable (the daemon did not answer)." \
      "Start Docker Desktop, or the Docker service (for example 'sudo systemctl start docker' on Linux), then run this launcher again."
  fi
  finish_step 2 OK "Docker Engine is running."
}

stage_compose() {
  begin_step 3 "Detecting Docker Compose v2..."
  if ! docker compose version >/dev/null 2>&1; then
    die_step 3 "Docker Compose v2 detection" \
      "Docker is installed, but the 'docker compose' (Compose v2) plugin is not available." \
      "Install or enable the Compose v2 plugin: $COMPOSE_INSTALL_URL"
  fi
  finish_step 3 OK "Docker Compose v2 is available."
}

stage_detect() {
  begin_step 4 "Checking for an existing project container or image..."
  _id=$(docker compose ps -q "$SERVICE" 2>/dev/null || true)
  if [ -n "$_id" ]; then
    CONTAINER_RUNNING=1
    REUSED_PORT=$(detect_running_port || true)
    _short=${_id%"${_id#????????????}"}
    finish_step 4 OK "Existing container detected (id ${_short}...)."
    say "Existing AG Learning Platform container detected."
    say "Reusing existing container — no rebuild or dependency installation needed."
  elif image_exists; then
    IMAGE_EXISTS=1
    finish_step 4 OK "Existing image detected; Python dependencies are already installed inside it."
  else
    finish_step 4 OK "No existing image found; a fresh build is required on this first run."
  fi
}

stage_port() {
  begin_step 5 "Selecting a local host port..."
  if [ "$CONTAINER_RUNNING" = 1 ]; then
    if is_valid_port "$REUSED_PORT"; then
      CHOSEN_PORT=$REUSED_PORT
      finish_step 5 OK "Using port ${CHOSEN_PORT} (published by the existing container)."
      return 0
    fi
    die_step 5 "Port selection" \
      "An existing container is running but no published port could be detected." \
      "Run 'docker compose port ${SERVICE} ${CONTAINER_PORT}' to inspect it, or 'docker compose down' and start again."
  fi
  if [ -n "${HOST_PORT:-}" ]; then
    if ! is_valid_port "$HOST_PORT"; then
      die_step 5 "Port selection" \
        "HOST_PORT='${HOST_PORT}' is not a valid TCP port (1-65535)." \
        "Set HOST_PORT to a number between 1 and 65535, for example HOST_PORT=8002 ./start.sh"
    fi
    if port_in_use "$HOST_PORT"; then
      die_step 5 "Port selection" \
        "Port ${HOST_PORT} (your HOST_PORT) is already in use by another program." \
        "Choose a different port, for example HOST_PORT=8002 ./start.sh"
    fi
    CHOSEN_PORT=$HOST_PORT
    finish_step 5 OK "Using port ${CHOSEN_PORT} (from HOST_PORT in your environment)."
    return 0
  fi
  _env_port=$(env_file_port || true)
  if [ -n "$_env_port" ]; then
    if ! is_valid_port "$_env_port"; then
      die_step 5 "Port selection" \
        "HOST_PORT in .env ('${_env_port}') is not a valid TCP port (1-65535)." \
        "Fix the HOST_PORT value in .env, or remove the line to use the default."
    fi
    if port_in_use "$_env_port"; then
      die_step 5 "Port selection" \
        "Port ${_env_port} (from HOST_PORT in .env) is already in use." \
        "Update HOST_PORT in .env to a free port, or remove the line."
    fi
    CHOSEN_PORT=$_env_port
    finish_step 5 OK "Using port ${CHOSEN_PORT} (from HOST_PORT in .env)."
    return 0
  fi
  CHOSEN_PORT=$(find_free_port 8000 || true)
  if [ -z "$CHOSEN_PORT" ]; then
    die_step 5 "Port selection" \
      "No free port was found between 8000 and ${PORT_SCAN_MAX}." \
      "Stop some local services, or set HOST_PORT to a free port."
  fi
  if [ "$CHOSEN_PORT" = "8000" ]; then
    finish_step 5 OK "Using port 8000 (default; it is free)."
  else
    finish_step 5 OK "Using port ${CHOSEN_PORT} (8000 was busy; the next free port was chosen)."
  fi
}

stage_build() {
  if [ "$CONTAINER_RUNNING" = 1 ]; then
    finish_step 6 SKIP "Skipped: reusing the running container (no rebuild)."
    return 0
  fi
  if [ "$IMAGE_EXISTS" = 1 ]; then
    finish_step 6 SKIP "Skipped: image already built; Python dependencies are already inside it."
    return 0
  fi
  begin_step 6 "Building the image and installing Python dependencies..."
  say "Python dependencies are installed inside the Docker image, not on your host OS."
  say "Streaming Docker build output below (the first build can take a minute)..."
  if ! docker compose build; then
    die_step 6 "Image build and Python dependencies" \
      "The Docker image failed to build (a Docker build or 'pip install' error)." \
      "Read the build output above, fix the Dockerfile or requirements.txt, then run this launcher again."
  fi
  finish_step 6 OK "Image built; Python dependencies are installed inside the image."
}

stage_start() {
  if [ "$CONTAINER_RUNNING" = 1 ]; then
    finish_step 7 SKIP "Skipped: the container is already running (reused)."
    return 0
  fi
  begin_step 7 "Starting the container..."
  if ! docker compose up -d; then
    die_step 7 "Container startup" \
      "Docker Compose could not start the container." \
      "Review the output above and the logs below, fix the problem, then run this launcher again."
  fi
  finish_step 7 OK "Container started."
}

stage_seed() {
  if [ "$CONTAINER_RUNNING" = 1 ]; then
    finish_step 8 OK "Migrations and fictional demo data were preserved (existing container reused)."
    return 0
  fi
  begin_step 8 "Waiting for Django migrations and fictional demo seeding..."
  if ! wait_for_seed; then
    die_step 8 "Django migration and demo seeding" \
      "The container did not report 'Demo data ready' within ${READINESS_TIMEOUT}s (migration or seeding may have failed)." \
      "Check the logs below, then run this launcher again."
  fi
  finish_step 8 OK "Django migrations ran and fictional demo data is ready."
}

stage_http() {
  begin_step 9 "Checking HTTP readiness at http://127.0.0.1:${CHOSEN_PORT}/ ..."
  if ! wait_for_http "http://127.0.0.1:${CHOSEN_PORT}/"; then
    die_step 9 "HTTP readiness check" \
      "The service started but did not answer HTTP at http://127.0.0.1:${CHOSEN_PORT}/ within ${READINESS_TIMEOUT}s." \
      "The app may still be starting; wait and retry, or run 'docker compose logs ${SERVICE}'."
  fi
  finish_step 9 OK "HTTP health check passed at http://127.0.0.1:${CHOSEN_PORT}/."
}

print_success() {
  finalize_progress
  printf '\n'
  if [ "$USE_COLOR" = 1 ]; then
    printf '%sYour demo is running (local development only).%s\n\n' "$c_green" "$c_reset"
  else
    printf 'Your demo is running (local development only).\n\n'
  fi
  printf '  Home:  http://127.0.0.1:%s/\n' "$CHOSEN_PORT"
  printf '  Login: http://127.0.0.1:%s/login/\n\n' "$CHOSEN_PORT"
  printf '  Demo accounts (fictional):\n'
  printf '    Admin:   demo_admin   / demo-admin-pass\n'
  printf '    Teacher: demo_teacher / demo-teacher-pass\n'
  printf '    Student: demo_student / demo-student-pass\n\n'
  printf '  Passwords are applied only when the demo accounts are first created.\n'
  printf '  If you changed a password earlier, your new password is kept.\n\n'
  printf '  Stop the demo safely:  docker compose down\n\n'
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------
start_or_detect() {
  trap 'on_interrupt' INT TERM
  printf 'AG Learning Platform Demo - setup\n'
  printf 'Local development only. This launcher is non-destructive.\n\n'
  stage_docker_cli
  stage_engine
  stage_compose
  stage_detect
  stage_port
  export HOST_PORT="$CHOSEN_PORT"
  stage_build
  stage_start
  stage_seed
  stage_http
  print_success
}

# ---------------------------------------------------------------------------
# Self-test (pure logic; used by tests/launcher_test.sh)
# ---------------------------------------------------------------------------
run_self_test() {
  _failures=0
  _assert() {
    if [ "$2" != "$3" ]; then
      printf 'FAIL - %s (expected %s got %s)\n' "$1" "$2" "$3"
      _failures=$((_failures + 1))
    else
      printf 'ok   - %s\n' "$1"
    fi
  }
  _expect() {
    if is_valid_port "$2"; then _got=0; else _got=1; fi
    _assert "$1" "$3" "$_got"
  }

  _expect "valid port 1" "1" 0
  _expect "valid port 8000" "8000" 0
  _expect "valid port 65535" "65535" 0
  _expect "invalid empty" "" 1
  _expect "invalid zero" "0" 1
  _expect "invalid text" "abc" 1
  _expect "invalid high" "70000" 1
  _expect "invalid negative" "-1" 1
  _expect "invalid injection" "80;rm -rf /" 1

  _assert "clean plain value" "8000" "$(clean_env_value '8000')"
  _assert "clean spaced value" "8000" "$(clean_env_value '  8000  ')"
  _assert "clean double-quoted" "8000" "$(clean_env_value '"8000"')"
  _assert "clean single-quoted" "8000" "$(clean_env_value "'8000'")"

  _assert "percent at 0 steps" "0" "$(percent_for 0)"
  _assert "percent at 8/9 is not 100" "88" "$(percent_for 8)"
  _assert "percent reaches 100 only at 9/9" "100" "$(percent_for 9)"
  _assert "percent clamps above total" "100" "$(percent_for 42)"

  _bar0=$(bar_for 0)
  _bar9=$(bar_for 9)
  _assert "bar length at 0" "$BAR_WIDTH" "${#_bar0}"
  _assert "bar length at 9" "$BAR_WIDTH" "${#_bar9}"
  case "$_bar0" in
    *'#'*) _assert "bar at 0 has no fill" "none" "found" ;;
    *) _assert "bar at 0 has no fill" "none" "none" ;;
  esac
  case "$_bar9" in
    *'-'*) _assert "bar at 9 is full" "full" "partial" ;;
    *) _assert "bar at 9 is full" "full" "full" ;;
  esac

  _free=$(find_free_port 8000 || true)
  if is_valid_port "$_free"; then
    printf 'ok   - find_free_port returned %s\n' "$_free"
  else
    printf 'FAIL - find_free_port returned an invalid value\n'
    _failures=$((_failures + 1))
  fi

  if [ "$_failures" -eq 0 ]; then
    printf 'start.sh self-test passed.\n'
    exit 0
  fi
  exit 1
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
case "${1:-}" in
  --no-color)
    NO_COLOR=1
    export NO_COLOR
    shift
    ;;
esac

case "${1:-}" in
  --help | -h)
    cat <<EOF
AG Learning Platform Demo launcher

Usage:
  ./start.sh                 Start (or reuse) the demo, preferring port 8000.
  HOST_PORT=9000 ./start.sh  Use an explicit host port.
  NO_COLOR=1 ./start.sh      Plain output without colour.
  ./start.sh --no-color      Same as NO_COLOR=1.
  ./start.sh --self-test     Run internal checks and exit.

The service is always bound to 127.0.0.1 only.
Stop the demo with: docker compose down
EOF
    exit 0
    ;;
  --self-test)
    init_display
    run_self_test
    ;;
  "")
    init_display
    start_or_detect
    ;;
  *)
    printf 'Error: unknown argument %s. Use --help for usage.\n' "$1" >&2
    exit 2
    ;;
esac
