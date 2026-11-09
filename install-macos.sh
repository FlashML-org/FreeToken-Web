#!/usr/bin/env bash
#
# FreeToken installer for macOS Apple Silicon (Metal backend).
#
# Typical use:
#   curl -fsSL https://www.flashml.ai/install-macos.sh | bash
#
# Configurable:
#   FREETOKEN_SRC        existing engine checkout (skips git clone)
#   FREETOKEN_HOME       install root (default: ~/.freetoken)
#   FREETOKEN_PY_VERSION python for the venv (default: 3.12)
#   FREETOKEN_BIN_DIR    where to symlink `ft` (default: ~/.local/bin)
#   FREETOKEN_REPO       git URL (default: https://github.com/FlashML-org/FreeToken.git)
#   FREETOKEN_REF        git ref to clone (default: HEAD of default branch)
#
set -euo pipefail

FT_HOME="${FREETOKEN_HOME:-$HOME/.freetoken}"
VENV="$FT_HOME/venv"
SRC="${FREETOKEN_SRC:-$FT_HOME/src}"
PY_VERSION="${FREETOKEN_PY_VERSION:-3.12}"
BIN_DIR="${FREETOKEN_BIN_DIR:-$HOME/.local/bin}"
REPO="${FREETOKEN_REPO:-https://github.com/FlashML-org/FreeToken.git}"
FALLBACK_REPO="${FREETOKEN_FALLBACK_REPO:-https://github.com/jasonkneen/FreeToken.git}"
# Default to the Metal branch until it is the repo default. Override with
# FREETOKEN_REF=main after that lands.
REF="${FREETOKEN_REF:-feat/apple-metal-backend}"

die() { printf '[error] %s\n' "$*" >&2; exit 1; }
say() { printf '==> %s\n' "$*"; }

[ "$(uname -s)" = Darwin ] || die "this installer is macOS-only (this is $(uname -s))"
[ "$(uname -m)" = arm64 ] || die "Apple Silicon (arm64) required — this machine is $(uname -m). An Intel/Rosetta shell cannot install mlx."

if command -v uv >/dev/null 2>&1; then
  UV="$(command -v uv)"
else
  command -v curl >/dev/null 2>&1 || die "need curl to bootstrap uv"
  say "bootstrapping uv into $BIN_DIR ..."
  mkdir -p "$BIN_DIR"
  UV_UNMANAGED_INSTALL="$BIN_DIR" curl -LsSf https://astral.sh/uv/install.sh | sh
  UV="$BIN_DIR/uv"
  [ -x "$UV" ] || die "uv bootstrap failed — install from https://docs.astral.sh/uv/"
fi
say "uv $($UV --version | awk '{print $2}')"

metal_ready() {
  local pp="$1/pyproject.toml"
  [ -f "$pp" ] || return 1
  grep -Eq "platform_system == ['\"]Linux['\"]" "$pp" && grep -Eq "torch[^;]*;[[:space:]]*platform_system" "$pp"
}

clone_engine() {
  local branch="$1"
  command -v git >/dev/null 2>&1 || die "need git to clone FreeToken"
  [ "$SRC" = "$FT_HOME/src" ] || die "won't clone over FREETOKEN_SRC=$SRC"
  mkdir -p "$(dirname "$SRC")"
  rm -rf "$SRC"
  say "cloning $REPO ($branch) into $SRC"
  if git clone --depth 1 --branch "$branch" "$REPO" "$SRC"; then
    return 0
  fi
  say "$REPO has no $branch; trying $FALLBACK_REPO"
  rm -rf "$SRC"
  git clone --depth 1 --branch "$branch" "$FALLBACK_REPO" "$SRC" \
    || die "could not clone $branch from $REPO or $FALLBACK_REPO"
}

if [ ! -f "$SRC/pyproject.toml" ]; then
  clone_engine "$REF"
fi

# The Metal path requires CUDA-only deps to be Linux-marked. A CUDA-only tree
# (today's default branch) would pull NVIDIA torch/flashlib and fail on macOS.
if ! metal_ready "$SRC"; then
  if [ -n "${FREETOKEN_SRC:-}" ] && [ "$SRC" = "$FREETOKEN_SRC" ]; then
    die "FREETOKEN_SRC=$SRC is CUDA-only and cannot install on macOS. Point it at a Metal-capable checkout, or unset FREETOKEN_SRC to clone $REF."
  fi
  say "tree at $SRC is CUDA-only; fetching $REF"
  clone_engine "$REF"
  metal_ready "$SRC" || die "cloned $REF but it is still CUDA-only"
fi

say "creating venv at $VENV (python $PY_VERSION)"
mkdir -p "$FT_HOME"
"$UV" venv "$VENV" --python "$PY_VERSION" --clear
say "installing FreeToken (editable) from $SRC"
"$UV" pip install --python "$VENV" -e "$SRC"
say "installing mlx-lm (Apple Metal engine)"
"$UV" pip install --python "$VENV" mlx-lm

FT_BIN="$VENV/bin/ft"
[ -x "$FT_BIN" ] || die "install finished but $FT_BIN is missing"
mkdir -p "$BIN_DIR"
ln -sf "$FT_BIN" "$BIN_DIR/ft"
say "symlinked $BIN_DIR/ft -> $FT_BIN"

if "$FT_BIN" --help >/dev/null 2>&1; then
  say "self-check: ft --help OK"
else
  die "self-check failed — inspect with: $FT_BIN --help"
fi

cat <<EOF

FreeToken (Metal) installed.

  ft binary     $FT_BIN
  on PATH as    $BIN_DIR/ft   (ensure $BIN_DIR is on PATH)

Run:
  ft serve --model mlx-community/Qwen3-0.6B-4bit --port 1919

EOF
