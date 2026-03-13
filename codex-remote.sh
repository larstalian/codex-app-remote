#!/usr/bin/env bash
set -euo pipefail

DEFAULT_CONFIG="${HOME}/.codex/remote-ssh-v0.toml"
DEFAULT_REMOTE_PORT=9234
LOCAL_PORT_START=47000
LOCAL_PORT_END=48999
MANAGED_BEGIN="# >>> codex-remote setup >>>"
MANAGED_END="# <<< codex-remote setup <<<"

usage() {
  cat <<'EOF'
Prepare a Linux SSH host for the hidden Codex desktop remote-host flow.

Usage:
  codex-remote.sh --ssh-alias NAME [options]
  codex-remote.sh --ssh-host HOST [options]

Options:
  --ssh-alias NAME       SSH alias to use. Recommended.
  --ssh-host HOST        Direct SSH target, such as user@host or host.
  --ssh-port PORT        Override the SSH port.
  --identity PATH        Override the SSH identity file.
  --workspace-path PATH  Remote project directory to verify.
  --display-name NAME    Friendly name to store in the local Codex config.
  --host-id ID           Override the generated hidden Codex host id.
  --local-port PORT      Override the local tunnel port Codex should use.
  --remote-port PORT     Remote `codex app-server` port. Defaults to 9234.
  --config PATH          Output path for the hidden Codex SSH config.
                         Defaults to ~/.codex/remote-ssh-v0.toml.
  --apply                Apply the remote PATH fix if needed and write the config.
  --no-backup            Overwrite the local config without making a backup.
  --help                 Show this help text.

Notes:
  - Tailscale is optional. Any reachable SSH target works.
  - The remote host must already have the `codex` CLI installed.
  - The no-sudo PATH fix currently supports bash and zsh.

Examples:
  ./codex-remote.sh --ssh-host <user>@<host>
  ./codex-remote.sh --ssh-host <user>@<host> --apply
  ./codex-remote.sh --ssh-alias <alias> --apply
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*"
}

pass() {
  printf 'PASS  %s\n' "$*"
}

warn() {
  printf 'WARN  %s\n' "$*" >&2
}

is_integer() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

expand_local_path() {
  local path="$1"
  case "$path" in
    "~")
      printf '%s\n' "$HOME"
      ;;
    "~/"*)
      printf '%s/%s\n' "$HOME" "${path#"~/"}"
      ;;
    *)
      printf '%s\n' "$path"
      ;;
  esac
}

shell_basename() {
  basename "${1:-}"
}

lookup_ssh_value() {
  local key="$1"
  local file="$2"
  awk -v wanted="$key" '$1 == wanted { $1 = ""; sub(/^ /, ""); print; exit }' "$file"
}

pick_ssh_identity() {
  local file="$1"
  local raw_path=""
  local expanded_path=""
  while IFS= read -r raw_path; do
    [[ -n "$raw_path" && "$raw_path" != "none" ]] || continue
    expanded_path="$(expand_local_path "$raw_path")"
    if [[ -f "$expanded_path" ]]; then
      printf '%s\n' "$expanded_path"
      return 0
    fi
  done < <(awk '$1 == "identityfile" { $1 = ""; sub(/^ /, ""); print }' "$file")
  return 1
}

slugify() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  if [[ -z "$value" ]]; then
    value="remote-host"
  fi
  printf '%s\n' "$value"
}

toml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\"'\"'/g")"
}

strip_cr() {
  tr -d '\r'
}

first_line() {
  local file="$1"
  sed -n '1p' "$file" | strip_cr
}

single_line_file() {
  local file="$1"
  strip_cr <"$file" | tr -d '\n'
}

find_free_port() {
  local port
  for port in $(seq "$LOCAL_PORT_START" "$LOCAL_PORT_END"); do
    if ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      printf '%s\n' "$port"
      return 0
    fi
  done
  return 1
}

home_relative_path() {
  local path="$1"
  local remote_home="$2"
  if [[ -n "$remote_home" && "$path" == "$remote_home" ]]; then
    printf '$HOME\n'
  elif [[ -n "$remote_home" && "$path" == "$remote_home/"* ]]; then
    printf '$HOME/%s\n' "${path#"$remote_home"/}"
  else
    printf '%s\n' "$path"
  fi
}

build_login_probe_cmd() {
  local remote_shell_path="$1"
  local probe="$2"
  case "$(shell_basename "$remote_shell_path")" in
    bash|zsh)
      printf '%s -lic %s\n' "$remote_shell_path" "$(shell_quote "$probe")"
      ;;
    fish)
      printf '%s -ic %s\n' "$remote_shell_path" "$(shell_quote "$probe")"
      ;;
    sh|dash|ash|ksh)
      printf '%s -lc %s\n' "$remote_shell_path" "$(shell_quote "$probe")"
      ;;
    *)
      printf 'if command -v bash >/dev/null 2>&1; then bash -lic %s; else exit 12; fi\n' "$(shell_quote "$probe")"
      ;;
  esac
}

expand_remote_path() {
  local path="$1"
  local remote_home="$2"
  if [[ -z "$path" ]]; then
    printf '\n'
    return 0
  fi
  if [[ -z "$remote_home" ]]; then
    printf '%s\n' "$path"
    return 0
  fi
  case "$path" in
    "~")
      printf '%s\n' "$remote_home"
      ;;
    "~/"*)
      printf '%s/%s\n' "$remote_home" "${path#"~/"}"
      ;;
    "$HOME")
      printf '%s\n' "$remote_home"
      ;;
    "$HOME/"*)
      printf '%s/%s\n' "$remote_home" "${path#"$HOME"/}"
      ;;
    *)
      printf '%s\n' "$path"
      ;;
  esac
}

print_toml() {
  printf '# Generated by %s on %s\n' "$(basename "$0")" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  printf '# This hidden Codex desktop config appears to accept a single SSH host.\n'
  printf 'host_id = "%s"\n' "$(toml_escape "$host_id")"
  printf 'display_name = "%s"\n' "$(toml_escape "$display_name")"
  printf 'local_port = %s\n' "$local_port"
  printf 'ssh_host = "%s"\n' "$(toml_escape "$ssh_host")"
  if [[ -n "$ssh_port" ]]; then
    printf 'ssh_port = %s\n' "$ssh_port"
  fi
  if [[ -n "$identity" ]]; then
    printf 'identity = "%s"\n' "$(toml_escape "$identity")"
  fi
  printf 'remote_port = %s\n' "$remote_port"
}

write_local_config() {
  local output="$1"
  local backup_existing="$2"
  local tmp_file=""
  local backup_path=""

  mkdir -p "$(dirname "$output")"
  tmp_file="$(mktemp)"
  print_toml >"$tmp_file"

  if [[ -f "$output" ]]; then
    if cmp -s "$tmp_file" "$output"; then
      rm -f "$tmp_file"
      pass "Local Codex config already matches $output"
      return 0
    fi

    if [[ "$backup_existing" -eq 1 ]]; then
      backup_path="${output}.bak-$(date '+%Y%m%d%H%M%S')"
      cp "$output" "$backup_path"
      pass "Backed up the previous local config to $backup_path"
    fi
  fi

  mv "$tmp_file" "$output"
  chmod 600 "$output" 2>/dev/null || true
  pass "Wrote the hidden Codex config to $output"
}

apply_remote_path_fix() {
  local remote_shell="$1"
  local remote_home="$2"
  local remote_codex_path="$3"
  local hook_file=""
  local hook_mode=""
  local env_file=""
  local env_dir_expr=""
  local env_file_expr=""
  local env_content=""
  local hook_block=""
  local apply_cmd=""

  if [[ -z "$remote_home" ]]; then
    die "could not determine the remote home directory, so the no-sudo PATH fix cannot be applied"
  fi

  case "$(shell_basename "$remote_shell")" in
    bash)
      hook_file="$remote_home/.bashrc"
      hook_mode="before-bash-guard"
      ;;
    zsh)
      hook_file="$remote_home/.zshenv"
      hook_mode="prepend"
      ;;
    *)
      die "plain SSH cannot see codex, and the no-sudo fix currently supports only bash and zsh; remote shell is: ${remote_shell:-unknown}"
      ;;
  esac

  env_file="$remote_home/.config/codex/noninteractive-env.sh"
  env_dir_expr="$(home_relative_path "$(dirname "$remote_codex_path")" "$remote_home")"
  env_file_expr="$(home_relative_path "$env_file" "$remote_home")"

  env_content="$(printf '%s\n' \
    '# Managed by codex-remote.sh' \
    'case ":$PATH:" in' \
    "  *:$env_dir_expr:*) ;;" \
    "  *) PATH=\"$env_dir_expr:\$PATH\" ;;" \
    'esac' \
    'export PATH')"

  hook_block="$(printf '%s\n' \
    "$MANAGED_BEGIN" \
    "[ -f \"$env_file_expr\" ] && . \"$env_file_expr\"" \
    "$MANAGED_END")"

  apply_cmd="$(printf '%s\n' \
    'set -e' \
    "hook_file=$(shell_quote "$hook_file")" \
    "env_file=$(shell_quote "$env_file")" \
    "hook_mode=$(shell_quote "$hook_mode")" \
    "marker_begin=$(shell_quote "$MANAGED_BEGIN")" \
    "marker_end=$(shell_quote "$MANAGED_END")" \
    'mkdir -p "$(dirname "$env_file")"' \
    "cat > \"\$env_file\" <<'CODEX_ENV'" \
    "$env_content" \
    'CODEX_ENV' \
    '' \
    'clean_file=$(mktemp)' \
    'snippet_file=$(mktemp)' \
    'new_file=$(mktemp)' \
    '' \
    "cat > \"\$snippet_file\" <<'CODEX_SNIPPET'" \
    "$hook_block" \
    'CODEX_SNIPPET' \
    '' \
    'if [ -f "$hook_file" ]; then' \
    '  cp "$hook_file" "$hook_file.bak.codex-$(date +%Y%m%d%H%M%S)"' \
    "  awk -v begin=\"\$marker_begin\" -v end=\"\$marker_end\" '" \
    '    $0 == begin { skip=1; next }' \
    '    $0 == end { skip=0; next }' \
    '    skip == 0 { print }' \
    "  ' \"\$hook_file\" > \"\$clean_file\"" \
    'else' \
    '  : > "$clean_file"' \
    'fi' \
    '' \
    'if [ "$hook_mode" = "before-bash-guard" ] && grep -n '"'"'^case \$- in'"'"' "$clean_file" >/dev/null 2>&1; then' \
    '  target=$(grep -n '"'"'^case \$- in'"'"' "$clean_file" | head -n 1 | cut -d: -f1)' \
    "  awk -v target=\"\$target\" -v snippet=\"\$snippet_file\" '" \
    '    NR == target {' \
    '      while ((getline line < snippet) > 0) {' \
    '        print line' \
    '      }' \
    '      close(snippet)' \
    '    }' \
    '    { print }' \
    "  ' \"\$clean_file\" > \"\$new_file\"" \
    'else' \
    '  cat "$snippet_file" "$clean_file" > "$new_file"' \
    'fi' \
    '' \
    'mv "$new_file" "$hook_file"' \
    'rm -f "$clean_file" "$snippet_file"')"

  if "${ssh_cmd[@]}" "sh -lc $(shell_quote "$apply_cmd")"; then
    pass "Installed the managed no-sudo PATH hook in $hook_file"
  else
    die "could not install the managed no-sudo PATH hook"
  fi
}

ssh_alias=""
ssh_host=""
ssh_port=""
identity=""
identity_from_flag=0
display_name=""
host_id=""
local_port=""
remote_port="$DEFAULT_REMOTE_PORT"
config_path="$DEFAULT_CONFIG"
workspace_path=""
apply_mode=0
backup_existing=1
resolved_file=""
remote_shell=""
remote_home=""
remote_os=""
workspace_resolved=""
menu_host=""

cleanup() {
  if [[ -n "$resolved_file" && -f "$resolved_file" ]]; then
    rm -f "$resolved_file"
  fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-alias)
      [[ $# -ge 2 ]] || die "--ssh-alias requires a value"
      ssh_alias="$2"
      shift 2
      ;;
    --ssh-host)
      [[ $# -ge 2 ]] || die "--ssh-host requires a value"
      ssh_host="$2"
      shift 2
      ;;
    --ssh-port)
      [[ $# -ge 2 ]] || die "--ssh-port requires a value"
      ssh_port="$2"
      shift 2
      ;;
    --identity)
      [[ $# -ge 2 ]] || die "--identity requires a value"
      identity="$2"
      identity_from_flag=1
      shift 2
      ;;
    --workspace-path)
      [[ $# -ge 2 ]] || die "--workspace-path requires a value"
      workspace_path="$2"
      shift 2
      ;;
    --display-name)
      [[ $# -ge 2 ]] || die "--display-name requires a value"
      display_name="$2"
      shift 2
      ;;
    --host-id)
      [[ $# -ge 2 ]] || die "--host-id requires a value"
      host_id="$2"
      shift 2
      ;;
    --local-port)
      [[ $# -ge 2 ]] || die "--local-port requires a value"
      local_port="$2"
      shift 2
      ;;
    --remote-port)
      [[ $# -ge 2 ]] || die "--remote-port requires a value"
      remote_port="$2"
      shift 2
      ;;
    --config)
      [[ $# -ge 2 ]] || die "--config requires a value"
      config_path="$2"
      shift 2
      ;;
    --apply)
      apply_mode=1
      shift
      ;;
    --no-backup)
      backup_existing=0
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

if [[ -n "$ssh_alias" ]]; then
  resolved_file="$(mktemp)"
  if ! ssh -G "$ssh_alias" >"$resolved_file"; then
    die "could not resolve SSH alias '$ssh_alias' via ssh -G"
  fi

  if [[ -z "$ssh_host" ]]; then
    ssh_host="$ssh_alias"
  fi
  if [[ -z "$ssh_port" ]]; then
    ssh_port="$(lookup_ssh_value port "$resolved_file" || true)"
  fi
  if [[ -z "$identity" ]]; then
    identity="$(pick_ssh_identity "$resolved_file" || true)"
    if [[ -z "$identity" ]]; then
      warn "No usable SSH identity file was resolved from alias '$ssh_alias'; relying on your SSH config."
    fi
  fi
  if [[ -z "$display_name" ]]; then
    display_name="$ssh_alias"
  fi
  menu_host="$ssh_alias"
fi

if [[ -z "$ssh_host" ]]; then
  die "set either --ssh-alias or --ssh-host"
fi

if [[ -z "$display_name" ]]; then
  display_name="$ssh_host"
fi

if [[ -z "$menu_host" ]]; then
  menu_host="$display_name"
  warn "Using --ssh-host without a named SSH alias can make the host harder to find in Codex > Hosts. A real alias in ~/.ssh/config is recommended."
fi

if [[ -n "$ssh_port" ]] && ! is_integer "$ssh_port"; then
  die "--ssh-port must be an integer"
fi

if [[ -n "$local_port" ]] && ! is_integer "$local_port"; then
  die "--local-port must be an integer"
fi

if ! is_integer "$remote_port"; then
  die "--remote-port must be an integer"
fi

if [[ -n "$identity" ]]; then
  identity="$(expand_local_path "$identity")"
  if [[ "$identity_from_flag" -eq 1 && ! -f "$identity" ]]; then
    die "--identity does not exist locally: $identity"
  fi
  if [[ "$identity_from_flag" -eq 0 && ! -f "$identity" ]]; then
    warn "Skipping SSH identity path that does not exist locally: $identity"
    identity=""
  fi
fi

if [[ -z "$host_id" ]]; then
  host_id="$(slugify "$display_name")"
fi

if [[ -z "$local_port" ]]; then
  local_port="$(find_free_port)" || die "could not find an open local port between ${LOCAL_PORT_START}-${LOCAL_PORT_END}"
fi

ssh_args=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
if [[ -n "$ssh_port" ]]; then
  ssh_args+=(-p "$ssh_port")
fi
if [[ -n "$identity" ]]; then
  ssh_args+=(-i "$identity")
fi
ssh_cmd=(ssh "${ssh_args[@]}" "$ssh_host")

info "Codex Remote SSH"
info "Target: $ssh_host"
info "Display name: $display_name"
info "Remote app-server port: $remote_port"
if [[ -n "$workspace_path" ]]; then
  info "Requested workspace: $workspace_path"
fi
if [[ "$apply_mode" -eq 1 ]]; then
  info "Mode: apply"
else
  info "Mode: dry run"
fi
printf '\n'

ssh_probe_out="$(mktemp)"
ssh_probe_err="$(mktemp)"
if "${ssh_cmd[@]}" 'printf "__codex_remote_ok__\n"' >"$ssh_probe_out" 2>"$ssh_probe_err"; then
  if grep -q '__codex_remote_ok__' "$ssh_probe_out"; then
    pass "SSH login succeeded."
  else
    sed 's/^/      /' "$ssh_probe_err" >&2 || true
    die "SSH returned, but the expected marker was missing"
  fi
else
  sed 's/^/      /' "$ssh_probe_err" >&2 || true
  die "SSH login failed. Make sure the Mac can already run plain SSH against this target."
fi
rm -f "$ssh_probe_out" "$ssh_probe_err"

os_out="$(mktemp)"
os_err="$(mktemp)"
if "${ssh_cmd[@]}" 'uname -srm' >"$os_out" 2>"$os_err"; then
  remote_os="$(single_line_file "$os_out")"
  pass "Remote OS: $remote_os"
fi
rm -f "$os_out" "$os_err"

home_out="$(mktemp)"
home_err="$(mktemp)"
if "${ssh_cmd[@]}" 'printf "%s\n" "$HOME"' >"$home_out" 2>"$home_err"; then
  remote_home="$(single_line_file "$home_out")"
fi
rm -f "$home_out" "$home_err"

shell_out="$(mktemp)"
shell_err="$(mktemp)"
if "${ssh_cmd[@]}" 'printf "%s\n" "${SHELL:-}"' >"$shell_out" 2>"$shell_err"; then
  remote_shell="$(single_line_file "$shell_out")"
fi
rm -f "$shell_out" "$shell_err"

if [[ -z "$remote_shell" ]]; then
  shell_out="$(mktemp)"
  shell_err="$(mktemp)"
  if "${ssh_cmd[@]}" 'getent passwd "$(id -un)" | cut -d: -f7' >"$shell_out" 2>"$shell_err"; then
    remote_shell="$(single_line_file "$shell_out")"
  fi
  rm -f "$shell_out" "$shell_err"
fi

plain_codex_out="$(mktemp)"
plain_codex_err="$(mktemp)"
if "${ssh_cmd[@]}" 'command -v codex && codex app-server --help >/dev/null 2>&1' >"$plain_codex_out" 2>"$plain_codex_err"; then
  pass "Plain SSH sees codex at: $(first_line "$plain_codex_out")"
else
  login_probe='if ! command -v codex >/dev/null 2>&1; then echo __missing_codex__; exit 10; fi; command -v codex; if codex app-server --help >/dev/null 2>&1; then echo __codex_app_server_ok__; exit 0; fi; echo __missing_app_server__; exit 11'
  login_probe_cmd="$(build_login_probe_cmd "$remote_shell" "$login_probe")"
  login_out="$(mktemp)"
  login_err="$(mktemp)"
  if "${ssh_cmd[@]}" "$login_probe_cmd" >"$login_out" 2>"$login_err"; then
    remote_codex_path="$(first_line "$login_out")"
    pass "Login shell sees codex at: $remote_codex_path"

    if [[ "$apply_mode" -eq 0 ]]; then
      warn "Plain SSH cannot see codex yet."
      warn "Dry run only. Re-run with --apply to install the managed no-sudo PATH hook."
    else
      apply_remote_path_fix "$remote_shell" "$remote_home" "$remote_codex_path"
    fi
  else
    case "$(tail -n 1 "$login_out" 2>/dev/null | strip_cr | tr -d '\n')" in
      __missing_codex__)
        die "the remote host does not have the codex CLI installed"
        ;;
      __missing_app_server__)
        die "the remote codex CLI was found, but it does not expose app-server"
        ;;
      *)
        sed 's/^/      /' "$login_err" >&2 || true
        die "could not verify codex from the remote login shell"
        ;;
    esac
  fi
  rm -f "$login_out" "$login_err"

  if [[ "$apply_mode" -eq 1 ]]; then
    verify_out="$(mktemp)"
    verify_err="$(mktemp)"
    if "${ssh_cmd[@]}" 'command -v codex && codex app-server --help >/dev/null 2>&1' >"$verify_out" 2>"$verify_err"; then
      pass "Plain SSH now sees codex at: $(first_line "$verify_out")"
    else
      sed 's/^/      /' "$verify_err" >&2 || true
      die "the PATH fix was applied, but plain SSH still cannot run codex app-server"
    fi
    rm -f "$verify_out" "$verify_err"
  fi
fi
rm -f "$plain_codex_out" "$plain_codex_err"

if [[ -n "$workspace_path" ]]; then
  workspace_resolved="$(expand_remote_path "$workspace_path" "$remote_home")"
  if "${ssh_cmd[@]}" "test -d $(shell_quote "$workspace_resolved")"; then
    pass "Remote workspace exists: $workspace_resolved"
  else
    die "remote workspace path does not exist: $workspace_resolved"
  fi
fi

if [[ "$apply_mode" -eq 0 ]]; then
  printf '\n'
  info "Dry run complete. Nothing was changed."
  info "Re-run with --apply to write $config_path and apply the no-sudo PATH fix if needed."
  exit 0
fi

write_local_config "$config_path" "$backup_existing"

printf '\n'
info "Next"
info "1. Restart Codex if it is already open."
info "2. In the macOS menu bar, choose: Codex > Hosts > (remote) $menu_host"
info "3. A separate remote window should open."
if [[ -n "$workspace_resolved" ]]; then
  info "4. In that remote window, choose File > Open Folder... and enter: $workspace_resolved"
else
  info "4. In that remote window, choose File > Open Folder... and enter your Linux project path."
fi
info "5. If File > Open Folder... still behaves like a local macOS picker, switch to the remote window and try again."
