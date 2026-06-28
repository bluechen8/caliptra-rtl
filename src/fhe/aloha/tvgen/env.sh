# Source to get a Go toolchain + the existing module cache (offline-capable).
# Use go from PATH if present; otherwise fall back to the self-contained install
# (override the fallback with GO_TOOLCHAIN_BIN=<dir>).
command -v go >/dev/null 2>&1 || export PATH="${GO_TOOLCHAIN_BIN:-/scratch/boru/go-toolchain/go/bin}:$PATH"
export GOPATH="${GOPATH:-$HOME/go}"
export GOTOOLCHAIN=local      # use installed 1.26.4; do not auto-download another toolchain
export GOFLAGS=-mod=mod
