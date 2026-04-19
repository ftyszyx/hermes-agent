#!/usr/bin/env bash
# Canonical test runner for hermes-agent. Run this instead of calling
# `pytest` directly to guarantee your local run matches CI behavior.
#
# What this script enforces:
#   * -n 4 xdist workers (CI has 4 cores; -n auto diverges locally)
#   * TZ=UTC, LANG=C.UTF-8, PYTHONHASHSEED=0 (deterministic)
#   * Credential env vars blanked (conftest.py also does this, but this
#     is belt-and-suspenders for anyone running `pytest` outside of
#     our conftest path — e.g. calling pytest on a single file)
#   * Proper venv activation
#
# Usage:
#   scripts/run_tests.sh                     # full suite
#   scripts/run_tests.sh tests/agent/        # one directory
#   scripts/run_tests.sh tests/agent/test_foo.py::TestClass::test_method
#   scripts/run_tests.sh --tb=long -v        # pass-through pytest args

set -euo pipefail

# ── Locate repo root ────────────────────────────────────────────────────────
# Works whether this is the main checkout or a worktree.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Locate venv Python ──────────────────────────────────────────────────────
# Prefer a .venv in the current tree, fall back to the main checkout's venv
# (useful for worktrees where we don't always duplicate the venv). Support
# both Unix-style virtualenvs and Windows .venv\Scripts layouts when the
# wrapper is run via Git Bash.
VENV=""
PYTHON=""
for candidate in \
  "$REPO_ROOT/.venv" \
  "$REPO_ROOT/venv" \
  "$HOME/.hermes/hermes-agent/.venv" \
  "$HOME/.hermes/hermes-agent/venv"
do
  if [ -f "$candidate/bin/python" ]; then
    VENV="$candidate"
    PYTHON="$candidate/bin/python"
    break
  fi
  if [ -f "$candidate/Scripts/python.exe" ]; then
    VENV="$candidate"
    PYTHON="$candidate/Scripts/python.exe"
    break
  fi
done

if [ -z "$PYTHON" ]; then
  echo "error: no virtualenv found with bin/python or Scripts/python.exe in $REPO_ROOT/.venv or $REPO_ROOT/venv" >&2
  exit 1
fi

# ── Ensure test runner deps are installed ──────────────────────────────────
# Some local setups sync only runtime deps (for example `uv sync` without the
# dev group / extras). Make the canonical wrapper self-healing so it can still
# enforce CI-parity flags without asking the user to switch tools.
# Keep these versions aligned with [project.optional-dependencies].dev in
# pyproject.toml, but install them directly so Windows doesn't need to
# reinstall the editable project and replace .venv\Scripts\hermes.exe.
if ! "$PYTHON" -m pip --version >/dev/null 2>&1; then
  echo "→ bootstrapping pip into $VENV"
  "$PYTHON" -m ensurepip --upgrade >/dev/null
fi

if ! "$PYTHON" -c "import pytest, pytest_asyncio, xdist, pytest_split" 2>/dev/null; then
  echo "→ installing test runner dependencies into $VENV"
  "$PYTHON" -m pip install --quiet \
    "pytest>=9.0.2,<10" \
    "pytest-asyncio>=1.3.0,<2" \
    "pytest-xdist>=3.0,<4" \
    "pytest-split>=0.9,<1"
fi

# ── Hermetic environment ────────────────────────────────────────────────────
# Mirror what CI does in .github/workflows/tests.yml + what conftest.py does.
# Unset every credential-shaped var currently in the environment.
while IFS='=' read -r name _; do
  case "$name" in
    *_API_KEY|*_TOKEN|*_SECRET|*_PASSWORD|*_CREDENTIALS|*_ACCESS_KEY| \
    *_SECRET_ACCESS_KEY|*_PRIVATE_KEY|*_OAUTH_TOKEN|*_WEBHOOK_SECRET| \
    *_ENCRYPT_KEY|*_APP_SECRET|*_CLIENT_SECRET|*_CORP_SECRET|*_AES_KEY| \
    AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN|FAL_KEY| \
    GH_TOKEN|GITHUB_TOKEN)
      unset "$name"
      ;;
  esac
done < <(env)

# Unset HERMES_* behavioral vars too.
unset HERMES_YOLO_MODE HERMES_INTERACTIVE HERMES_QUIET HERMES_TOOL_PROGRESS \
      HERMES_TOOL_PROGRESS_MODE HERMES_MAX_ITERATIONS HERMES_SESSION_PLATFORM \
      HERMES_SESSION_CHAT_ID HERMES_SESSION_CHAT_NAME HERMES_SESSION_THREAD_ID \
      HERMES_SESSION_SOURCE HERMES_SESSION_KEY HERMES_GATEWAY_SESSION \
      HERMES_PLATFORM HERMES_INFERENCE_PROVIDER HERMES_MANAGED HERMES_DEV \
      HERMES_CONTAINER HERMES_EPHEMERAL_SYSTEM_PROMPT HERMES_TIMEZONE \
      HERMES_REDACT_SECRETS HERMES_BACKGROUND_NOTIFICATIONS HERMES_EXEC_ASK \
      HERMES_HOME_MODE 2>/dev/null || true

# Pin deterministic runtime.
export TZ=UTC
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PYTHONHASHSEED=0

# ── Worker count ────────────────────────────────────────────────────────────
# CI uses `-n auto` on ubuntu-latest which gives 4 workers. A 20-core
# workstation with `-n auto` gets 20 workers and exposes test-ordering
# flakes that CI will never see. Pin to 4 so local matches CI.
WORKERS="${HERMES_TEST_WORKERS:-4}"

# ── Run pytest ──────────────────────────────────────────────────────────────
cd "$REPO_ROOT"

# If the first argument starts with `-` treat all args as pytest flags;
# otherwise treat them as test paths.
ARGS=("$@")

echo "▶ running pytest with $WORKERS workers, hermetic env, in $REPO_ROOT"
echo "  (TZ=UTC LANG=C.UTF-8 PYTHONHASHSEED=0; all credential env vars unset)"

# -o "addopts=" clears pyproject.toml's `-n auto` so our -n wins.
exec "$PYTHON" -m pytest \
  -o "addopts=" \
  -n "$WORKERS" \
  --ignore=tests/integration \
  --ignore=tests/e2e \
  -m "not integration" \
  "${ARGS[@]}"
