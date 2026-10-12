#!/bin/sh
#
# launcher_test.sh - tests for start.sh / start.ps1 without extra dependencies.
#
# Uses temporary directories and a parametrised mock `docker`, `curl` and
# `python3` to exercise every launcher branch (missing Docker, stopped daemon,
# missing Compose, existing container reuse, existing image reuse, fresh build,
# busy-port fallback, readiness/seed timeouts, secret redaction, noninteractive
# output) without touching containers, volumes or databases.
#
# Usage: sh tests/launcher_test.sh

set -u

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
START="$ROOT/start.sh"
PS_START="$ROOT/start.ps1"
SH_BIN=$(command -v sh)

PASS=0
FAIL=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

ok() {
    printf 'ok   - %s\n' "$1"
    PASS=$((PASS + 1))
}

no() {
    printf 'FAIL - %s\n' "$1"
    FAIL=$((FAIL + 1))
}

# ---------------------------------------------------------------------------
# Parametrised mock commands
# ---------------------------------------------------------------------------
MOCKBIN="$WORK/bin"
mkdir -p "$MOCKBIN"
LOG="$WORK/calls.log"
: >"$LOG"

cat >"$MOCKBIN/docker" <<'MOCK'
#!/bin/sh
case "$1" in
  info)
    exit "${INFO_RC:-0}"
    ;;
  image)
    exit "${IMAGE_INSPECT_RC:-1}"
    ;;
  compose)
    case "$2" in
      version)
        exit "${COMPOSE_VERSION_RC:-0}"
        ;;
      ps)
        case "$3" in
          -q) echo "${PS_Q:-}" ;;
          -aq) echo "${PS_AQ:-}" ;;
          -a) echo "${PS_A_STATE:-running}" ;;
          --status) echo "${PS_RUNNING:-}" ;;
        esac
        exit 0
        ;;
      port)
        echo "${COMPOSE_PORT:-}"
        exit 0
        ;;
      config)
        echo "${CONFIG_IMAGES:-ag-learning-platform-demo-web}"
        exit 0
        ;;
      build)
        echo "BUILD: installing Python dependencies inside the image"
        echo "BUILD" >>"${LOG:-/dev/null}"
        exit "${BUILD_RC:-0}"
        ;;
      up)
        echo "UP HOST_PORT=${HOST_PORT:-}" >>"${LOG:-/dev/null}"
        exit "${UP_RC:-0}"
        ;;
      logs)
        echo "${LOGS_OUT:-}"
        exit 0
        ;;
    esac
    exit 0
    ;;
esac
exit 0
MOCK
chmod +x "$MOCKBIN/docker"

cat >"$MOCKBIN/python3" <<'MOCK'
#!/bin/sh
last=""
for a in "$@"; do last="$a"; done
case " ${BUSY_PORTS:-} " in
  *" $last "*) exit 0 ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$MOCKBIN/python3"

cat >"$MOCKBIN/curl" <<'MOCK'
#!/bin/sh
exit "${CURL_RC:-0}"
MOCK
chmod +x "$MOCKBIN/curl"

reset_env() {
    export INFO_RC=0
    export COMPOSE_VERSION_RC=0
    export IMAGE_INSPECT_RC=1
    export BUILD_RC=0
    export UP_RC=0
    export CURL_RC=0
    export BUSY_PORTS=""
    export PS_Q=""
    export PS_AQ=""
    export PS_A_STATE="running"
    export PS_RUNNING=""
    export COMPOSE_PORT=""
    export CONFIG_IMAGES="ag-learning-platform-demo-web"
    export LOGS_OUT=""
    export LOG="$WORK/calls.log"
    export CASE_HOST_PORT=""
    export CASE_TIMEOUT="90"
    export CASE_INTERVAL="2"
    export NO_COLOR=1
}

# Run start.sh (or start.ps1) with the current mock environment.
run_shell() {
    : >"$LOG"
    out=$(PATH="$MOCKBIN:$PATH" HOST_PORT="${CASE_HOST_PORT}" \
        READINESS_TIMEOUT="${CASE_TIMEOUT}" READINESS_INTERVAL="${CASE_INTERVAL}" \
        "$SH_BIN" "$START" 2>&1)
    rc=$?
}

run_ps() {
    : >"$LOG"
    out=$(PATH="$MOCKBIN:$PATH" HOST_PORT="${CASE_HOST_PORT}" \
        READINESS_TIMEOUT="${CASE_TIMEOUT}" READINESS_INTERVAL="${CASE_INTERVAL}" \
        NO_COLOR=1 pwsh -NoProfile -File "$PS_START" 2>&1)
    rc=$?
}

has() { printf '%s' "$out" | grep -qF -- "$1"; }
nothas() { ! printf '%s' "$out" | grep -qF -- "$1"; }
log_has() { grep -qF -- "$1" "$LOG"; }
log_not() { ! grep -qF -- "$1" "$LOG"; }

ESC=$(printf '\033')
CR=$(printf '\r')

# ---------------------------------------------------------------------------
# 1. Shell syntax + self-tests
# ---------------------------------------------------------------------------
if "$SH_BIN" -n "$START" 2>/dev/null; then
    ok "start.sh passes 'sh -n' syntax check"
else
    no "start.sh failed 'sh -n' syntax check"
fi

if "$SH_BIN" "$START" --self-test >/dev/null 2>&1; then
    ok "start.sh --self-test passes"
else
    no "start.sh --self-test failed"
fi

# ---------------------------------------------------------------------------
# 2. Missing Docker -> guidance, ERROR stage, no 100%
# ---------------------------------------------------------------------------
missing_bin="$WORK/missing_docker_bin"
mkdir -p "$missing_bin"
ln -s "$(command -v dirname)" "$missing_bin/dirname"
ln -s "$(command -v cat)" "$missing_bin/cat"
out=$(PATH="$missing_bin" "$SH_BIN" "$START" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && has "Docker CLI detection" && has "Setup failed"; then
    ok "missing Docker fails at the Docker CLI stage (exit $rc)"
else
    no "missing Docker not handled (exit $rc)"
fi
if has "https://docs.docker.com/get-docker/" && has "Likely cause" && has "Next step"; then
    ok "missing Docker reports cause, next step and install URL"
else
    no "missing Docker message incomplete"
fi
if nothas "100%"; then
    ok "missing Docker never shows 100%"
else
    no "missing Docker showed 100%"
fi

# ---------------------------------------------------------------------------
# 3. Docker Engine stopped (installed but not started)
# ---------------------------------------------------------------------------
reset_env
INFO_RC=1
run_shell
if [ "$rc" -ne 0 ] && has "Docker Engine availability" && has "not running or not reachable"; then
    ok "stopped Docker Engine reported distinctly from 'not installed' (exit $rc)"
else
    no "stopped Docker Engine not handled (exit $rc)"
fi

# ---------------------------------------------------------------------------
# 4. Docker Compose v2 missing
# ---------------------------------------------------------------------------
reset_env
COMPOSE_VERSION_RC=1
run_shell
if [ "$rc" -ne 0 ] && has "Compose v2 detection" && has "plugin is not available"; then
    ok "missing Compose v2 is detected (exit $rc)"
else
    no "missing Compose v2 not handled (exit $rc)"
fi

# ---------------------------------------------------------------------------
# 5. Existing container reuse -> exact lines, no build/up, 100%, clean output
# ---------------------------------------------------------------------------
reset_env
PS_Q="deadbeefdeadbeefdeadbeef"
COMPOSE_PORT="127.0.0.1:8000"
CURL_RC=0
run_shell
if [ "$rc" -eq 0 ] && has "Existing AG Learning Platform container detected." &&
    has "no rebuild or dependency installation needed"; then
    ok "already-running container prints the exact reuse messages (exit $rc)"
else
    no "already-running reuse messages missing (exit $rc)"
fi
if has "http://127.0.0.1:8000/" && has "Setup steps completed" && has "100%"; then
    ok "reuse path reaches 100% and shows the real URL"
else
    no "reuse path missing URL or 100%"
fi
if log_not "BUILD" && log_not "UP"; then
    ok "reuse path performs no build and no compose up (no duplicate setup)"
else
    no "reuse path unexpectedly built or restarted"
fi
if nothas "$ESC" && nothas "$CR"; then
    ok "noninteractive reuse output has no colour or carriage-return clutter"
else
    no "noninteractive reuse output contains control characters"
fi

# ---------------------------------------------------------------------------
# 6. Existing image (container stopped) -> skip build, still start
# ---------------------------------------------------------------------------
reset_env
PS_Q=""
IMAGE_INSPECT_RC=0
LOGS_OUT="Demo data ready: 6 courses, 18 lessons."
CURL_RC=0
run_shell
if [ "$rc" -eq 0 ] && has "Existing image detected" && has "100%"; then
    ok "existing image is reused without rebuild (exit $rc)"
else
    no "existing image reuse failed (exit $rc)"
fi
if log_not "BUILD" && log_has "UP"; then
    ok "existing-image path skips build but starts the container"
else
    no "existing-image path build/start behaviour wrong"
fi

# ---------------------------------------------------------------------------
# 7. Fresh build with live output
# ---------------------------------------------------------------------------
reset_env
PS_Q=""
IMAGE_INSPECT_RC=1
BUILD_RC=0
LOGS_OUT="Demo data ready: 6 courses, 18 lessons."
CURL_RC=0
run_shell
if [ "$rc" -eq 0 ] && has "BUILD: installing Python dependencies inside the image"; then
    ok "fresh build streams live Docker build output (exit $rc)"
else
    no "fresh build did not stream output (exit $rc)"
fi
if has "inside the Docker image, not on your host OS" && has "Image built"; then
    ok "fresh build explains dependencies live inside the image"
else
    no "fresh build explanation missing"
fi
if log_has "BUILD" && log_has "UP" && has "100%"; then
    ok "fresh build builds, starts, and reaches 100%"
else
    no "fresh build did not build+start to 100%"
fi
if nothas "Existing AG Learning Platform container detected."; then
    ok "fresh build does not claim an existing container"
else
    no "fresh build wrongly claimed an existing container"
fi

# ---------------------------------------------------------------------------
# 8. Busy port fallback (8000 busy -> 8001)
# ---------------------------------------------------------------------------
reset_env
PS_Q=""
IMAGE_INSPECT_RC=0
BUSY_PORTS="8000"
LOGS_OUT="Demo data ready: 6 courses, 18 lessons."
CURL_RC=0
run_shell
if [ "$rc" -eq 0 ] && has "Using port 8001" && has "8000 was busy"; then
    ok "busy 8000 falls back to 8001 with a reason (exit $rc)"
else
    no "busy-port fallback failed (exit $rc)"
fi
if has "http://127.0.0.1:8001/" && log_has "UP HOST_PORT=8001"; then
    ok "fallback port is passed to Compose and used for the URL"
else
    no "fallback port not propagated"
fi

# ---------------------------------------------------------------------------
# 9. Explicit HOST_PORT honoured / busy HOST_PORT rejected
# ---------------------------------------------------------------------------
reset_env
CASE_HOST_PORT="8123"
PS_Q=""
IMAGE_INSPECT_RC=0
LOGS_OUT="Demo data ready: 6 courses, 18 lessons."
CURL_RC=0
run_shell
if [ "$rc" -eq 0 ] && has "Using port 8123 (from HOST_PORT in your environment)" &&
    has "http://127.0.0.1:8123/"; then
    ok "explicit HOST_PORT=8123 is honoured"
else
    no "explicit HOST_PORT override not honoured (exit $rc)"
fi

reset_env
CASE_HOST_PORT="8000"
PS_Q=""
IMAGE_INSPECT_RC=0
BUSY_PORTS="8000"
run_shell
if [ "$rc" -ne 0 ] && has "already in use" && nothas "100%"; then
    ok "busy explicit HOST_PORT fails with guidance and no 100% (exit $rc)"
else
    no "busy explicit HOST_PORT not handled (exit $rc)"
fi

# ---------------------------------------------------------------------------
# 10. HTTP readiness timeout -> failure, no 100%
# ---------------------------------------------------------------------------
reset_env
PS_Q=""
IMAGE_INSPECT_RC=0
LOGS_OUT="Demo data ready: 6 courses, 18 lessons."
CURL_RC=1
CASE_TIMEOUT=2
CASE_INTERVAL=1
run_shell
if [ "$rc" -ne 0 ] && has "HTTP readiness check" && has "Likely cause"; then
    ok "HTTP readiness timeout fails with cause/next step (exit $rc)"
else
    no "readiness timeout not handled (exit $rc)"
fi
if nothas "100%"; then
    ok "readiness timeout never reports 100%"
else
    no "readiness timeout wrongly reported 100%"
fi

# ---------------------------------------------------------------------------
# 11. Seed timeout -> failure at the migration/seeding stage
# ---------------------------------------------------------------------------
reset_env
PS_Q=""
IMAGE_INSPECT_RC=0
LOGS_OUT="Applying migrations..."
CASE_TIMEOUT=2
CASE_INTERVAL=1
run_shell
if [ "$rc" -ne 0 ] && has "demo seeding" && nothas "100%"; then
    ok "seed/migration timeout fails without 100% (exit $rc)"
else
    no "seed timeout not handled (exit $rc)"
fi

# ---------------------------------------------------------------------------
# 12. Failure logs are sanitized (no secrets)
# ---------------------------------------------------------------------------
reset_env
PS_Q=""
IMAGE_INSPECT_RC=0
PS_AQ="deadbeefdeadbeef"
LOGS_OUT="startup: DEMO_ADMIN_PASSWORD=demo-admin-pass DJANGO_SECRET_KEY=super-secret-value; Demo data ready"
CURL_RC=1
CASE_TIMEOUT=2
CASE_INTERVAL=1
run_shell
if has "PASSWORD=***" && has "SECRET_KEY=***"; then
    ok "failure logs mask passwords and secret keys"
else
    no "failure logs were not redacted"
fi
if nothas "demo-admin-pass" && nothas "super-secret-value"; then
    ok "failure logs do not leak the secret values"
else
    no "failure logs leaked a secret value"
fi

# ---------------------------------------------------------------------------
# 13. Interactive TTY output (colour + progress bar), best-effort
# ---------------------------------------------------------------------------
if command -v script >/dev/null 2>&1 && script -qec true /dev/null >/dev/null 2>&1; then
    reset_env
    unset NO_COLOR
    export PS_Q="deadbeefdeadbeefdeadbeef"
    export COMPOSE_PORT="127.0.0.1:8000"
    export CURL_RC=0
    : >"$LOG"
    tty_out=$(env -u NO_COLOR PATH="$MOCKBIN:$PATH" "$SH_BIN" -c "script -qec '$SH_BIN $START' /dev/null" 2>&1 || true)
    if printf '%s' "$tty_out" | grep -qF "$ESC"; then
        ok "interactive TTY output uses colour codes"
    else
        no "interactive TTY output missing colour"
    fi
    if printf '%s' "$tty_out" | grep -qF "Setup steps completed" &&
        printf '%s' "$tty_out" | grep -qF "100%"; then
        ok "interactive TTY output shows the progress bar reaching 100%"
    else
        no "interactive TTY progress bar missing"
    fi
    if printf '%s' "$tty_out" | grep -qF "$CR"; then
        ok "interactive TTY output redraws the progress line in place"
    else
        no "interactive TTY output did not use carriage-return redraw"
    fi
else
    printf 'skip - no compatible script(1); interactive TTY checks not run\n'
fi

# ---------------------------------------------------------------------------
# 14. PowerShell: parse + self-test + mock reuse/timeout integration
# ---------------------------------------------------------------------------
if command -v pwsh >/dev/null 2>&1 && [ -f "$PS_START" ]; then
    if pwsh -NoProfile -NonInteractive -Command "\$e=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('$PS_START',[ref]\$null,[ref]\$e); if(\$e -and \$e.Count){ exit 1 } else { exit 0 }" >/dev/null 2>&1; then
        ok "start.ps1 passes PowerShell parser check"
    else
        no "start.ps1 failed PowerShell parser check"
    fi
    if pwsh -NoProfile -NonInteractive -File "$PS_START" -SelfTest >/dev/null 2>&1; then
        ok "start.ps1 -SelfTest passes"
    else
        no "start.ps1 -SelfTest failed"
    fi

    case "$(uname -s 2>/dev/null || echo unknown)" in
      MINGW* | MSYS* | CYGWIN*)
        printf 'skip - PowerShell Docker-mock integration not run on Windows\n'
        ;;
      *)
        reset_env
        PS_Q="deadbeefdeadbeefdeadbeef"
        COMPOSE_PORT="127.0.0.1:8000"
        CURL_RC=0
        run_ps
        if [ "$rc" -eq 0 ] && has "Existing AG Learning Platform container detected." && has "100%"; then
            ok "start.ps1 reuses the running container and reaches 100%"
        else
            no "start.ps1 reuse path failed (exit $rc)"
        fi
        if log_not "BUILD" && log_not "UP"; then
            ok "start.ps1 reuse path does not rebuild or restart"
        else
            no "start.ps1 reuse path unexpectedly built/up"
        fi

        reset_env
        PS_Q=""
        IMAGE_INSPECT_RC=1
        BUILD_RC=0
        LOGS_OUT="Demo data ready: 6 courses, 18 lessons."
        CURL_RC=0
        run_ps
        if [ "$rc" -eq 0 ] && has "BUILD: installing Python dependencies inside the image" && has "100%"; then
            ok "start.ps1 fresh build streams output and reaches 100%"
        else
            no "start.ps1 fresh build failed (exit $rc)"
        fi

        reset_env
        PS_Q=""
        IMAGE_INSPECT_RC=0
        LOGS_OUT="Demo data ready: 6 courses, 18 lessons."
        CURL_RC=1
        CASE_TIMEOUT=2
        CASE_INTERVAL=1
        run_ps
        if [ "$rc" -ne 0 ] && has "HTTP readiness check" && nothas "100%"; then
            ok "start.ps1 readiness timeout fails without 100%"
        else
            no "start.ps1 readiness timeout not handled (exit $rc)"
        fi
        ;;
    esac
else
    printf 'skip - pwsh not available; PowerShell checks not run\n'
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
