#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  agent-sandbox-dev.sh [--tool opencode|pi|COMMAND] [--project DIR] [--allow-config PATH] [--] [ARGS...]

Examples:
  agent-sandbox-dev.sh
  agent-sandbox-dev.sh --tool pi
  agent-sandbox-dev.sh --project ~/src/my-app --tool opencode -- run

Runs the selected agent under a macOS sandbox-exec "dev" profile:
  - project directory: read/write
  - HOME: project-local .agent-sandbox/home
  - project-local .agent-sandbox/cache and tmp: read/write
  - system/tool paths: read-only
  - /Users, /Volumes, and /Network: denied by default, then selectively re-allowed
  - selected dotfiles/config directories: read-only
  - network: allowed

This is a lightweight safety boundary, not VM/container-grade isolation.
USAGE
}

die() {
  printf 'agent-sandbox-dev: %s\n' "$*" >&2
  exit 1
}

quote_scheme_string() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '"%s"' "$value"
}

print_ancestor_metadata_rules() {
  local path=$1
  while [[ "$path" != / ]]; do
    path=$(dirname "$path")
    [[ "$path" == / ]] && break
    printf '(allow file-read-metadata (literal %s))\n' "$(quote_scheme_string "$path")"
  done
}

append_env_if_set() {
  local name=$1
  local value
  eval "value=\${$name-}"
  [[ -n "$value" ]] && env_args+=("$name=$value")
  return 0
}

canonical_path() {
  local path=$1
  if [[ -d "$path" ]]; then
    (cd "$path" && pwd -P)
  else
    local dir base
    dir=$(dirname "$path")
    base=$(basename "$path")
    (cd "$dir" && printf '%s/%s\n' "$(pwd -P)" "$base")
  fi
}

link_config_path() {
  local path=$1
  [[ -e "$path" || -L "$path" ]] || return 0

  local source_path rel_path dest_path dest_parent
  source_path=$(canonical_path "$path")

  case "$source_path" in
    "$user_home"/*)
      rel_path=${source_path#"$user_home"/}
      ;;
    *)
      return 0
      ;;
  esac

  dest_path="$home_dir/$rel_path"
  dest_parent=$(dirname "$dest_path")
  mkdir -p "$dest_parent"

  if [[ -L "$dest_path" ]]; then
    [[ $(readlink "$dest_path") == "$source_path" ]] && return 0
    ln -sfn "$source_path" "$dest_path"
    return 0
  fi

  if [[ -e "$dest_path" ]]; then
    local backup_path
    backup_path="$dest_path.sandbox-backup.$(date +%Y%m%d%H%M%S)"
    mv "$dest_path" "$backup_path"
    printf 'agent-sandbox-dev: moved existing sandbox config path to: %s\n' "$backup_path" >&2
  fi

  ln -s "$source_path" "$dest_path"
}

tool=opencode
project=.
config_paths=()

writable_home_paths=(
  "$HOME/Library/Application Support/Code"
)

default_config_candidates=(
  "$HOME/.gitconfig"
  "$HOME/.config/git"
  "$HOME/.config/opencode"
  "$HOME/.config/pi"
  "$HOME/.config/gh"
  "$HOME/.config/github-copilot"
  "$HOME/.copilot"
  "$HOME/.local"
)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tool)
      [[ $# -ge 2 ]] || die '--tool requires a value'
      tool=$2
      shift 2
      ;;
    --project)
      [[ $# -ge 2 ]] || die '--project requires a directory'
      project=$2
      shift 2
      ;;
    --allow-config)
      [[ $# -ge 2 ]] || die '--allow-config requires a path'
      config_paths+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    opencode|pi)
      tool=$1
      shift
      ;;
    *)
      break
      ;;
  esac
done

command -v sandbox-exec >/dev/null 2>&1 || die 'sandbox-exec is not available on this macOS installation'
command -v "$tool" >/dev/null 2>&1 || die "cannot find tool on PATH: $tool"
[[ -d "$project" ]] || die "project directory does not exist: $project"

project_root=$(canonical_path "$project")
tool_path=$(command -v "$tool")
tool_path=$(canonical_path "$tool_path")
user_home=$(canonical_path "$HOME")

sandbox_root="$project_root/.agent-sandbox"
home_dir="$sandbox_root/home"
cache_dir="$sandbox_root/cache"
tmp_dir="$sandbox_root/tmp"
profile=$(mktemp -t agent-sandbox)

mkdir -p "$home_dir" "$cache_dir" "$tmp_dir"
trap 'rm -f "$profile"' EXIT

all_config_paths=("${default_config_candidates[@]}")
if [[ ${#config_paths[@]} -gt 0 ]]; then
  all_config_paths+=("${config_paths[@]}")
fi

for path in "${all_config_paths[@]}" "${writable_home_paths[@]}"; do
  link_config_path "$path"
done

terminal_paths=(/dev/null /dev/zero /dev/random /dev/urandom /dev/tty)
if tty_path=$(tty 2>/dev/null); then
  terminal_paths+=("$tty_path")
fi

{
  printf '(version 1)\n'
  printf '(deny default)\n\n'

  printf ';; Process, networking, and common system queries.\n'
  printf '(allow process*)\n'
  printf '(allow network*)\n'
  printf '(allow sysctl-read)\n'
  printf '(allow mach-lookup)\n\n'

  printf ';; Broad reads are needed for macOS dyld/runtime paths that are hard to enumerate.\n'
  printf '(allow file-read* (subpath "/"))\n'
  printf ';; Generic write-data is needed for inherited stdout/stderr pipes. Creation stays denied except below.\n'
  printf '(allow file-write-data)\n'
  for path in /Users /Volumes /Network /tmp /private/tmp; do
    [[ -e "$path" ]] && printf '(deny file-read* (subpath %s))\n' "$(quote_scheme_string "$path")"
    [[ -e "$path" ]] && printf '(deny file-write* (subpath %s))\n' "$(quote_scheme_string "$path")"
  done
  printf '\n'

  printf ';; Project and project-local sandbox state.\n'
  printf '(allow file-read* (subpath %s))\n' "$(quote_scheme_string "$project_root")"
  printf '(allow file-write* (subpath %s))\n' "$(quote_scheme_string "$project_root")"

  print_ancestor_metadata_rules "$project_root"

  printf '(allow file-read* (subpath %s))\n' "$(quote_scheme_string "$home_dir")"
  printf '(allow file-write* (subpath %s))\n' "$(quote_scheme_string "$home_dir")"
  printf '(allow file-read* (subpath %s))\n' "$(quote_scheme_string "$cache_dir")"
  printf '(allow file-write* (subpath %s))\n' "$(quote_scheme_string "$cache_dir")"
  printf '(allow file-read* (subpath %s))\n' "$(quote_scheme_string "$tmp_dir")"
  printf '(allow file-write* (subpath %s))\n\n' "$(quote_scheme_string "$tmp_dir")"

  printf ';; Common system runtime and tool locations, documented here for auditability.\n'
  for path in \
    /bin \
    /sbin \
    /usr \
    /System \
    /Library \
    /private/etc \
    /private/var/db \
    /opt/local \
    /opt/homebrew \
    /usr/local \
    /Applications/Xcode.app \
    /Library/Developer; do
    [[ -e "$path" ]] && printf '(allow file-read* (subpath %s))\n' "$(quote_scheme_string "$path")"
  done
  printf '(allow file-read* (literal %s))\n\n' "$(quote_scheme_string "$tool_path")"

  printf ';; Character devices needed by terminals and many CLI tools.\n'
  for path in /dev/fd /private/dev/fd; do
    [[ -e "$path" ]] && printf '(allow file-read* (subpath %s))\n' "$(quote_scheme_string "$path")"
    [[ -e "$path" ]] && printf '(allow file-write* (subpath %s))\n' "$(quote_scheme_string "$path")"
    [[ -e "$path" ]] && printf '(allow file-ioctl (subpath %s))\n' "$(quote_scheme_string "$path")"
  done
  for path in "${terminal_paths[@]}"; do
    [[ -e "$path" ]] && printf '(allow file-read* (literal %s))\n' "$(quote_scheme_string "$path")"
    [[ -e "$path" ]] && printf '(allow file-write* (literal %s))\n' "$(quote_scheme_string "$path")"
    [[ -e "$path" ]] && printf '(allow file-ioctl (literal %s))\n' "$(quote_scheme_string "$path")"
  done
  printf '\n'

  printf ';; Selected user config, read-only.\n'
  for path in "${all_config_paths[@]}"; do
    [[ -e "$path" ]] || continue
    real_path=$(canonical_path "$path")
    if [[ -d "$real_path" ]]; then
      printf '(allow file-read* (subpath %s))\n' "$(quote_scheme_string "$real_path")"
    else
      printf '(allow file-read* (literal %s))\n' "$(quote_scheme_string "$real_path")"
    fi
    print_ancestor_metadata_rules "$real_path"
  done

  printf '\n;; Selected home paths, writable through sandbox-home symlinks.\n'
  for path in "${writable_home_paths[@]}"; do
    [[ -e "$path" ]] || continue
    real_path=$(canonical_path "$path")
    printf '(allow file-read* (subpath %s))\n' "$(quote_scheme_string "$real_path")"
    printf '(allow file-write* (subpath %s))\n' "$(quote_scheme_string "$real_path")"
    print_ancestor_metadata_rules "$real_path"
  done
} > "$profile"

printf 'Running %s in sandboxed project: %s\n' "$tool" "$project_root" >&2

cd "$project_root"

env_args=(
  "HOME=$home_dir"
  "PATH=/opt/local/bin:/opt/local/sbin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  "TMPDIR=$tmp_dir"
  "XDG_CONFIG_HOME=$home_dir/.config"
  "XDG_CACHE_HOME=$cache_dir/xdg"
  "XDG_DATA_HOME=$home_dir/.local/share"
  "XDG_STATE_HOME=$home_dir/.local/state"
  "GIT_CONFIG_GLOBAL=$home_dir/.gitconfig"
  "npm_config_cache=$cache_dir/npm"
  "PIP_CACHE_DIR=$cache_dir/pip"
  "UV_CACHE_DIR=$cache_dir/uv"
  "CARGO_HOME=$cache_dir/cargo"
  "GOCACHE=$cache_dir/go-build"
  "GOMODCACHE=$cache_dir/go-mod"
)

for name in \
  TERM \
  COLORTERM \
  LANG \
  LC_ALL \
  LC_CTYPE \
  ANTHROPIC_API_KEY \
  ANTHROPIC_OAUTH_TOKEN \
  OPENAI_API_KEY \
  AZURE_OPENAI_API_KEY \
  AZURE_OPENAI_BASE_URL \
  AZURE_OPENAI_RESOURCE_NAME \
  AZURE_OPENAI_API_VERSION \
  AZURE_OPENAI_DEPLOYMENT_NAME_MAP \
  GEMINI_API_KEY \
  GOOGLE_API_KEY \
  DEEPSEEK_API_KEY \
  GROQ_API_KEY \
  CEREBRAS_API_KEY \
  XAI_API_KEY \
  FIREWORKS_API_KEY \
  OPENROUTER_API_KEY \
  AI_GATEWAY_API_KEY \
  ZAI_API_KEY \
  MISTRAL_API_KEY \
  MINIMAX_API_KEY \
  MOONSHOT_API_KEY \
  OPENCODE_API_KEY \
  KIMI_API_KEY \
  CLOUDFLARE_API_KEY \
  CLOUDFLARE_ACCOUNT_ID \
  CLOUDFLARE_GATEWAY_ID \
  PI_OFFLINE \
  PI_TELEMETRY; do
  append_env_if_set "$name"
done

exec sandbox-exec -f "$profile" /usr/bin/env -i "${env_args[@]}" "$tool" "$@"
