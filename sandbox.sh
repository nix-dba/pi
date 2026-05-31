#!/usr/bin/env bash

# Defaults
SHOW_HELP=false
NET_ARGS=(--share-net)
DO_VERBOSE=false
NO_GIT_INIT=false
EXTRA_WORKSPACES=()
MOUNT_SSH=false

# Parse CLI flags before any side effects
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      SHOW_HELP=true
      shift
      ;;
    --no-git-init)
      NO_GIT_INIT=true
      shift
      ;;
    --verbose|-v)
      DO_VERBOSE=true
      shift
      ;;
    --ssh-keys)
      MOUNT_SSH=true
      shift
      ;;
    --no-net)
      NET_ARGS=()
      shift
      ;;
    -w|--workspace)
      if [ -z "$2" ]; then
        echo "Error: --workspace requires a path argument" >&2
        exit 1
      fi
      EXTRA_WORKSPACES+=("$2")
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      echo "Use --help for usage" >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

# Show help and exit (no side effects)
if [ "$SHOW_HELP" = true ]; then
  cat <<EOF
Usage: sandbox.sh [OPTIONS] [COMMAND] [ARGS...]

Run pi agent inside a bubblewrap sandbox.

Options:
  -h, --help                Show this help message
  --no-git-init             Skip git repository initialization prompt
  --verbose, -v             Print the full bwrap command before execution
  --ssh-keys                Mount ~/.ssh read-only in the sandbox
  --no-net                  Disable network access in the sandbox
  -w, --workspace PATH      Bind additional workspace directory (can be repeated)

If no COMMAND is given, defaults to 'zellij' with a layout running pi.
EOF
  exit 0
fi

mkdir -p "$HOME/.pi/agent"
mkdir -p "$HOME/.config/tuicr"

# Temp files cleanup
# Script location for referencing bundled configs
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CLEANUP_FILES=()
cleanup() {
  rm -rf "${CLEANUP_FILES[@]}"
  find "$HOME/.config/pi" -mindepth 1 -type f -empty -delete 2>/dev/null
}
trap cleanup EXIT

# Zellij isolated config (tempdir, never touches host)
ZELLIJ_TMPDIR=$(mktemp -d)
CLEANUP_FILES+=("$ZELLIJ_TMPDIR")
ZELLIJ_VER=$(zellij --version | cut -d ' ' -f 2)
mkdir -p "$ZELLIJ_TMPDIR/config/zellij"
mkdir -p "$ZELLIJ_TMPDIR/cache/zellij/$ZELLIJ_VER"
touch "$ZELLIJ_TMPDIR/cache/zellij/$ZELLIJ_VER/seen_release_notes"
cat > "$ZELLIJ_TMPDIR/config/zellij/config.kdl" << 'EOF'
show_startup_tips false
show_release_notes false
default_shell "bash"
copy_command "wl-copy"
default_mode "locked"

keybinds {
    shared_except "locked" {

    }
}
EOF

# Git init with conditional prompt
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ "$NO_GIT_INIT" = true ] || [ ! -t 0 ]; then
    echo "Skipped git init"
  else
    read -r -p "$PWD is not a git repo. Initialize repository now? (y/N): " answer
    case "$answer" in
      [YyjJ]* )
        git init
        git add --all .
        echo "Initialized empty git repository"
        ;;
      * )
        echo "Skipped git init"
        ;;
    esac
  fi
fi

# Workspace binds
WORKSPACES=("$PWD" "${EXTRA_WORKSPACES[@]}")
WORKSPACE_BINDS=()
for ws in "${WORKSPACES[@]}"; do
  if [ -d "$ws" ]; then
    WORKSPACE_BINDS+=(--bind "$ws" "$ws")
  fi
done

# Wayland binds
WAYLAND_SOCKET="${XDG_RUNTIME_DIR:-/run/user/$UID}/${WAYLAND_DISPLAY:-wayland-0}"
if [ -S "$WAYLAND_SOCKET" ]; then
  WAYLAND_BINDS=(--bind "$WAYLAND_SOCKET" "$WAYLAND_SOCKET")
else
  WAYLAND_BINDS=()
fi

# Network bind mounts (conditional on --no-net)
NET_BINDS=()
if [ "${#NET_ARGS[@]}" -gt 0 ]; then
  NET_BINDS=(
    --ro-bind-try /var/run/docker.sock /var/run/docker.sock
    --ro-bind-try /etc/resolv.conf /etc/resolv.conf
    --ro-bind-try /etc/hosts /etc/hosts
    --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf
  )
fi

SSH_BINDS=()
if [ "$MOUNT_SSH" = true ] && [ -d "$HOME/.ssh" ]; then
  SSH_BINDS=(--ro-bind-try "$HOME/.ssh" "$HOME/.ssh")
fi

PI_SETTINGS_BINDS=()
if [ -n "$PI_SETTINGS_JSON" ] && [ -f "$PI_SETTINGS_JSON" ]; then
  pi_settings_tmp=$(mktemp)
  CLEANUP_FILES+=("$pi_settings_tmp")
  sed "s|\"~/|\"$HOME/|g" "$PI_SETTINGS_JSON" > "$pi_settings_tmp"
  PI_SETTINGS_BINDS+=(--ro-bind-try "$pi_settings_tmp" "$HOME/.pi/agent/settings.json")
fi

# Default command: zellij with layout, or user override
if [ $# -eq 0 ]; then
  CMD=(zellij --layout "$LAYOUT_KDL")
else
  CMD=("$@")
fi

# Assemble bwrap arguments
BWRAP_ARGS=(
  --unshare-all
  "${NET_ARGS[@]}"
  --die-with-parent
  # system bind mounts
  --ro-bind /usr /usr
  --ro-bind-try /lib /lib
  --ro-bind /lib64 /lib64
  --ro-bind /bin /bin
  --ro-bind-try /sbin /sbin
  --ro-bind-try /nix /nix
  --ro-bind /sys /sys
  "${NET_BINDS[@]}"
  --proc /proc
  --dev /dev
  --tmpfs /tmp
  --tmpfs /run
  "${WAYLAND_BINDS[@]}"
  --ro-bind-try /run/current-system/sw/bin /run/current-system/sw/bin
  --setenv XDG_RUNTIME_DIR "$XDG_RUNTIME_DIR"
  --setenv WAYLAND_DISPLAY "${WAYLAND_DISPLAY:-wayland-0}"
  # etc bind mounts
  --ro-bind-try /etc/ssl /etc/ssl
  --ro-bind-try /etc/pki /etc/pki
  --ro-bind-try /etc/ca-certificates /etc/ca-certificates
  --ro-bind-try /etc/nix /etc/nix
  --ro-bind-try /etc/static /etc/static
  --ro-bind-try /etc/alternatives /etc/alternatives
  --ro-bind-try /etc/passwd /etc/passwd
  --ro-bind-try /etc/group /etc/group
  --ro-bind-try /etc/machine-id /etc/machine-id
  --ro-bind-try /etc/subuid /etc/subuid
  --ro-bind-try /etc/subgid /etc/subgid
  # home dirs
  --dir "$HOME"
  --dir "${XDG_RUNTIME_DIR:-/run/user/$UID}"
  --setenv HOME "$HOME"
  --chdir "$PWD"
  # home bind mounts
  --bind-try "$HOME/.pi" "$HOME/.pi"
  --tmpfs "$HOME/.config/tuicr"
  --ro-bind-try "${TUICR_CONFIG:-$SCRIPT_DIR/default/tuicr/config.toml}" "$HOME/.config/tuicr/config.toml"
  --ro-bind-try "$HOME/.config/nix" "$HOME/.config/nix"
  --ro-bind-try "$HOME/.config/git" "$HOME/.config/git"
  --ro-bind-try "$HOME/.gitconfig" "$HOME/.gitconfig"
  --bind-try "$HOME/.cargo" "$HOME/.cargo"
  --ro-bind-try "$HOME/.local/share/fonts" "$HOME/.local/share/fonts"
  "${SSH_BINDS[@]}"
  "${PI_SETTINGS_BINDS[@]}"
  "${WORKSPACE_BINDS[@]}"
  --bind "$ZELLIJ_TMPDIR/config/zellij" "$HOME/.config/zellij"
  --bind "$ZELLIJ_TMPDIR/cache/zellij" "$HOME/.cache/zellij"
  --setenv TMPDIR /tmp
  --setenv NODE_TLS_REJECT_UNAUTHORIZED 0
  --setenv CARGO_NET_OFFLINE false
  --setenv SSL_CERT_FILE /etc/ssl/certs/ca-certificates.crt
  --setenv NIX_SSL_CERT_FILE /etc/ssl/certs/ca-certificates.crt
  --setenv GIT_SSL_CAINFO /etc/ssl/certs/ca-certificates.crt
  "${CMD[@]}"
)

# Verbose: print the command before executing
if [ "$DO_VERBOSE" = true ]; then
  echo "bwrap \\"
  for arg in "${BWRAP_ARGS[@]}"; do
    printf '  %q \\\n' "$arg"
  done
fi

bwrap "${BWRAP_ARGS[@]}"
