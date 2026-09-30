#!/usr/bin/env bash
# Stage the local opencodex checkout, verify its compatibility manifest, and transfer it to the
# configured VPS with incremental rsync into an isolated staging tree. The active remote source
# is used as an rsync --copy-dest basis so a repeat run transfers only changed file bytes. The
# target identity is read from a local, gitignored .env as data, never as shell code. No remote
# write happens until the operator types the target host at the prompt. The dashboard presents
# OpenCodeX's admin-token sign-in form; Caddy has no edge Basic Auth, and a gui pairing code
# (GUI browser pairing) is not accepted in place of the admin token.
# This script stays local; the matching scripts/deploy-ocx-vps.sh runs on the VPS.
set -euo pipefail

# Absolute location of this script and the repository it was run from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly REPO_ROOT

# Local, gitignored env file holding only the target IP and public hostname. It is parsed as
# data and is never transferred; OCX_ENV_FILE exists so tests can point at a fixture instead.
ENV_FILE="${OCX_ENV_FILE:-$REPO_ROOT/.env}"
# SSH identity and isolated remote layout. Every value is non-secret and explicitly overridable.
VPS_USER="${OCX_VPS_USER:-root}"
SSH_PORT="${OCX_VPS_SSH_PORT:-22}"
REMOTE_BASE="${OCX_VPS_REMOTE_BASE:-/root/ocx-vps}"
REMOTE_SOURCE_DIR="${REMOTE_BASE}/source"
REMOTE_SOURCE_PREVIOUS_DIR="${REMOTE_BASE}/source.previous"
REMOTE_STAGING_DIR="${REMOTE_BASE}/source-staging"
REMOTE_SCRIPT="${REMOTE_BASE}/deploy-ocx-vps.sh"
# Remote Compose identity used only to print the exact admin-token retrieval command. Defaults
# mirror scripts/deploy-ocx-vps.sh; override if that script runs with a different project name.
PROJECT_NAME="${OCX_PROJECT_NAME:-opencodex-vps}"
REMOTE_COMPOSE_OVERRIDE="${OCX_VPS_COMPOSE_OVERRIDE:-$REMOTE_BASE/compose.vps.yaml}"

# Target identity, filled only by parse_env_file from the two approved keys. No defaults exist.
HOST=""
DOMAIN=""

# Separate public dashboard hostname, explicit or derived from DOMAIN. The dashboard is never
# served on the data API hostname. No edge credential is held here; the admin token gates it.
DASHBOARD_DOMAIN=""

# Tracked paths the Docker build consumes; every other local file stays local by construction.
readonly SNAPSHOT_PATHS=(
  Dockerfile
  compose.yaml
  package.json
  bun.lock
  tsconfig.json
  src
  docker
  gui
  scripts/generate-compatibility-version.ts
  scripts/model-metadata.source.json
)

# Execution mode: dry run stages and verifies locally, run-remote executes the deploy script.
DRY_RUN=0
RUN_REMOTE=0

# Populated while staging: the verified snapshot tree and its portable SHA-256 command array.
STAGING=""
SHA256_CMD=()

# Write a progress line to stderr so stdout stays available for the plan.
log() { printf '[copy-ocx-vps] %s\n' "$*" >&2; }

# Abort with an actionable message and a non-zero exit status.
die() { printf '[copy-ocx-vps] ERROR: %s\n' "$*" >&2; exit 1; }

# Print the accepted flags and the meaning of each override.
usage() {
  cat >&2 <<'EOF'
Usage: scripts/copy-ocx-vps.sh [--dry-run] [--run-remote]

Stages the repository as a tracked-source snapshot, generates and verifies the
compatibility manifest, and mirrors it with rsync into an isolated remote staging
tree after a typed confirmation. The previous active source is kept until the
staged snapshot passes remote verification, and only then is it promoted.

Flags:
  --dry-run      Stage and verify locally and print the plan; perform no remote access.
  --run-remote   Execute the remote deploy script after promoting the verified snapshot.
  -h, --help     Show this help.

Overrides:
  OCX_ENV_FILE             Local env file to read (default <repo>/.env).
  OCX_VPS_USER             Target user (default root).
  OCX_VPS_SSH_PORT         SSH port (default 22).
  OCX_VPS_REMOTE_BASE      Isolated remote base directory (default /root/ocx-vps).
  OCX_DASHBOARD_DOMAIN     Explicit dashboard hostname; otherwise derived from OCX_DOMAIN.
  OCX_PROJECT_NAME         Compose project name for the printed token command (default opencodex-vps).
  OCX_VPS_COMPOSE_OVERRIDE Compose override path for the printed token command.

The env file must contain exactly one OCX_VPS_HOST (IPv4) and one OCX_DOMAIN
(public hostname). Values are read as data only; the file is never sourced and
is never copied to the VPS.

Sign-in: the dashboard form asks for the OpenCodeX admin token. Read it on the
VPS with the printed `docker compose ... exec hub cat .../admin-api-token`
command and paste the value into the form. An "Account" label you type there is
only a password-manager label. A one-time `ocx gui pair` code pairs a GUI
browser session and is not accepted by this admin-token sign-in form.
EOF
}

# Strip one layer of matching surrounding quotes without evaluating the value.
unquote_env_value() {
  local value="$1"
  case "$value" in
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
  esac
  printf '%s' "$value"
}

# True when the argument is a dotted-quad IPv4 address with octets in range.
validate_ipv4() {
  local ip="$1" octet
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for octet in "${BASH_REMATCH[@]:1:4}"; do
    ((10#$octet <= 255)) || return 1
  done
  return 0
}

# True when the argument is a dotted hostname with an alphabetic top-level label.
validate_hostname() {
  local host="$1"
  [ -n "$host" ] || return 1
  [ "${#host}" -le 253 ] || return 1
  [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] || return 1
  [[ "$host" =~ \.[A-Za-z]{2,}$ ]] || return 1
  return 0
}

# Choose the dashboard hostname: an explicit OCX_DASHBOARD_DOMAIN wins, otherwise derive it
# deterministically from the API domain by replacing its leftmost label with opencodex. A
# two-label domain is refused rather than guessed, so no arbitrary registrable domain is used.
derive_dashboard_domain() {
  if [ -n "${OCX_DASHBOARD_DOMAIN:-}" ]; then
    DASHBOARD_DOMAIN="$OCX_DASHBOARD_DOMAIN"
  else
    case "$DOMAIN" in
      *.*.*) DASHBOARD_DOMAIN="opencodex.${DOMAIN#*.}" ;;
      *) die "cannot derive a dashboard hostname from OCX_DOMAIN=$DOMAIN; set OCX_DASHBOARD_DOMAIN explicitly" ;;
    esac
  fi
  validate_hostname "$DASHBOARD_DOMAIN" || die "dashboard hostname is not a valid public hostname: $DASHBOARD_DOMAIN"
  [ "$DASHBOARD_DOMAIN" != "$DOMAIN" ] \
    || die "the dashboard hostname must differ from the data API hostname; refusing to expose the dashboard on $DOMAIN"
}

# Extract exactly OCX_VPS_HOST and OCX_DOMAIN from the env file as data, rejecting missing,
# duplicate, or malformed values. Unrelated keys are ignored and never read or printed.
parse_env_file() {
  local file="$ENV_FILE" line key value lineno=0 host_seen=0 domain_seen=0
  [ -f "$file" ] || die "local env file not found: $file; create it with OCX_VPS_HOST and OCX_DOMAIN"
  [ -r "$file" ] || die "local env file is not readable: $file"
  HOST=""
  DOMAIN=""
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    # Tolerate CRLF files without treating the carriage return as part of the value.
    line="${line%$'\r'}"
    case "$line" in
      '' | '#'*) continue ;;
    esac
    key="${line%%=*}"
    [ "$key" = "$line" ] && die "$file:$lineno: malformed line (expected KEY=VALUE)"
    value="${line#*=}"
    # Remove any whitespace from the key so 'KEY = value' is still recognised; the value is
    # validated as written so stray spaces are rejected rather than silently trimmed.
    key="${key//[[:space:]]/}"
    case "$key" in
      OCX_VPS_HOST)
        [ "$host_seen" -eq 0 ] || die "$file:$lineno: duplicate OCX_VPS_HOST"
        host_seen=1
        HOST="$(unquote_env_value "$value")"
        ;;
      OCX_DOMAIN)
        [ "$domain_seen" -eq 0 ] || die "$file:$lineno: duplicate OCX_DOMAIN"
        domain_seen=1
        DOMAIN="$(unquote_env_value "$value")"
        ;;
      *)
        # Ignore unrelated keys entirely; their values are neither read nor printed.
        ;;
    esac
  done < "$file"
  [ "$host_seen" -eq 1 ] || die "$file: missing OCX_VPS_HOST"
  [ "$domain_seen" -eq 1 ] || die "$file: missing OCX_DOMAIN"
  validate_ipv4 "$HOST" || die "$file: OCX_VPS_HOST is not a valid IPv4 address"
  validate_hostname "$DOMAIN" || die "$file: OCX_DOMAIN is not a valid public hostname"
}

# Reject values that would break SSH argument or remote path parsing. Remote paths allow only
# an unambiguous character set so they can be embedded in a remote command safely.
validate_target() {
  validate_ipv4 "$HOST" || die "OCX_VPS_HOST must be a valid IPv4 address"
  validate_hostname "$DOMAIN" || die "OCX_DOMAIN must be a valid public hostname"
  validate_hostname "$DASHBOARD_DOMAIN" || die "dashboard hostname must be a valid public hostname"
  [ "$DASHBOARD_DOMAIN" != "$DOMAIN" ] || die "dashboard hostname must differ from OCX_DOMAIN"
  [ -n "$VPS_USER" ] || die "OCX_VPS_USER must not be empty"
  case "$VPS_USER" in
    *[!A-Za-z0-9._-]*) die "OCX_VPS_USER contains unsupported characters: $VPS_USER" ;;
  esac
  case "$SSH_PORT" in
    ''|*[!0-9]*) die "OCX_VPS_SSH_PORT must be numeric: $SSH_PORT" ;;
  esac
  case "$REMOTE_BASE" in
    /*) : ;;
    *) die "OCX_VPS_REMOTE_BASE must be an absolute path: $REMOTE_BASE" ;;
  esac
  case "$REMOTE_BASE" in
    *[[:space:]]*|*..*|*/) die "OCX_VPS_REMOTE_BASE must be clean and space-free: $REMOTE_BASE" ;;
  esac
  case "$REMOTE_BASE" in
    *[!A-Za-z0-9._/-]*) die "OCX_VPS_REMOTE_BASE contains unsupported characters: $REMOTE_BASE" ;;
  esac
  case "$PROJECT_NAME" in
    ''|*[!A-Za-z0-9_.-]*) die "OCX_PROJECT_NAME is not a safe Compose project name: $PROJECT_NAME" ;;
  esac
  case "$REMOTE_COMPOSE_OVERRIDE" in
    /*) : ;;
    *) die "OCX_VPS_COMPOSE_OVERRIDE must be an absolute path: $REMOTE_COMPOSE_OVERRIDE" ;;
  esac
  case "$REMOTE_COMPOSE_OVERRIDE" in
    *[[:space:]]*|*..*) die "OCX_VPS_COMPOSE_OVERRIDE must be clean and space-free: $REMOTE_COMPOSE_OVERRIDE" ;;
  esac
  # Each managed path must be a direct, single-component child of the isolated base so no later
  # removal can be redirected through a nested or traversing path.
  local managed suffix
  for managed in "$REMOTE_SOURCE_DIR" "$REMOTE_SOURCE_PREVIOUS_DIR" "$REMOTE_STAGING_DIR"; do
    case "$managed" in
      "$REMOTE_BASE"/*) : ;;
      *) die "managed remote path must be a direct child of OCX_VPS_REMOTE_BASE: $managed" ;;
    esac
    suffix="${managed#"$REMOTE_BASE"/}"
    case "$suffix" in
      ''|*/*) die "managed remote path must be a single direct child of OCX_VPS_REMOTE_BASE: $managed" ;;
    esac
  done
}

# Fail early when a required local tool is missing, naming the tool.
require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "required local tool not found: $1"
}

# Verify the local tool set and pick a portable SHA-256 implementation.
check_local_tools() {
  require_tool git
  require_tool tar
  require_tool ssh
  require_tool rsync
  require_tool bun
  if command -v sha256sum >/dev/null 2>&1; then
    SHA256_CMD=(sha256sum)
  elif command -v shasum >/dev/null 2>&1; then
    SHA256_CMD=(shasum -a 256)
  else
    die "either sha256sum or shasum is required"
  fi
}

# Refuse tracked symlinks outright rather than following them out of the checkout.
detect_symlinks() {
  local entry mode path
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    mode="${entry%% *}"
    path="${entry#*$'\t'}"
    if [ "$mode" = "120000" ]; then
      die "tracked symlink is not allowed in the snapshot: $path"
    fi
  done < <(git -C "$REPO_ROOT" ls-files -s -z -- "${SNAPSHOT_PATHS[@]}" | tr '\0' '\n')
}

# Write the content-checksum manifest and file inventory from the staged bytes. Lines are literal
# `HASH<two spaces>PATH` (shasum-compatible with GNU sha256sum -c), and the two metadata files are
# excluded by exact name, never an `.ocx-*` glob.
write_snapshot_manifest() {
  local rel
  (
    cd "$STAGING"
    find . -type f ! -name '.ocx-manifest.sha256' ! -name '.ocx-inventory' -print | LC_ALL=C sort > .ocx-inventory
    while IFS= read -r rel; do
      printf '%s  %s\n' "$("${SHA256_CMD[@]}" "$rel" | awk '{print $1}')" "$rel"
    done < .ocx-inventory > .ocx-manifest.sha256
  )
}

# Build the snapshot from tracked files only, generate the Docker compatibility manifest, and
# record its checksums and inventory. Nothing outside the local staging tree is written here.
stage_snapshot() {
  mkdir -p "$REPO_ROOT/.tmp"
  STAGING="$(mktemp -d "$REPO_ROOT/.tmp/ocx-vps-stage.XXXXXX")"
  # Clean the local scratch artifact on every exit path, including failure.
  trap 'rm -rf "${STAGING:-}"' EXIT

  local listfile="$STAGING/.snapshot-paths"
  # The snapshot carries exactly the tracked allowlist; untracked files never enter it.
  if tar --null -cf /dev/null -T /dev/null >/dev/null 2>&1; then
    # `--null` reads the NUL-separated Git list unambiguously, so no path is split or lost.
    git -C "$REPO_ROOT" ls-files -z -- "${SNAPSHOT_PATHS[@]}" \
      | tar -C "$REPO_ROOT" --null -T - -cf - | tar -C "$STAGING" -xf -
  else
    # Portable fallback: a newline list cannot represent a newline in a path, so refuse those.
    local tracked_path
    while IFS= read -r -d '' tracked_path; do
      case "$tracked_path" in
        *$'\n'*) die "tracked path contains a newline; the tar list cannot represent it: $tracked_path" ;;
      esac
    done < <(git -C "$REPO_ROOT" ls-files -z -- "${SNAPSHOT_PATHS[@]}")
    git -C "$REPO_ROOT" ls-files -z -- "${SNAPSHOT_PATHS[@]}" | tr '\0' '\n' > "$listfile"
    tar -C "$REPO_ROOT" -cf - -T "$listfile" | tar -C "$STAGING" -xf -
    rm -f "$listfile"
  fi

  # A symlink that slipped through the mode check is a hard stop, not a silent copy.
  if find "$STAGING" -type l -print -quit | grep -q .; then
    die "snapshot contains a symlink; refusing to transfer it"
  fi

  # The manifest and inventory are newline-delimited, so a path containing a newline cannot be
  # represented in them; reject it before either file is generated.
  local staged_path
  while IFS= read -r -d '' staged_path; do
    case "$staged_path" in
      *$'\n'*) die "staged path contains a newline; the checksum manifest cannot represent it: $staged_path" ;;
    esac
  done < <(find "$STAGING" -type f -print0)

  # Generate the compatibility identity into the snapshot, never into tracked sources.
  bun "$REPO_ROOT/scripts/generate-compatibility-version.ts" "$REPO_ROOT" \
    "$STAGING/src/generated/compatibility-version.json" >/dev/null
  # Re-verify the exact staged bytes against the generated manifest.
  bun "$REPO_ROOT/docker/verify-compatibility.ts" "$STAGING"
  # Record checksums and a file inventory for the independent remote verification step.
  write_snapshot_manifest
}

# Describe the intended transfer and every remote effect before the confirmation prompt.
print_plan() {
  cat >&2 <<EOF
Plan:
  target          ${VPS_USER}@${HOST}:${SSH_PORT}
  public domain   ${DOMAIN} (data API)
  dashboard       ${DASHBOARD_DOMAIN} (OpenCodeX admin-token sign-in; no edge Basic Auth)
  env source      ${ENV_FILE} (read as data; never transferred)
  remote base     ${REMOTE_BASE}
  remote staging  ${REMOTE_STAGING_DIR} (rsync delta; stale files pruned only here)
  remote source   ${REMOTE_SOURCE_DIR} (kept until staging verifies, then promoted)
  basis           ${REMOTE_SOURCE_DIR} as rsync --copy-dest (remote-local copies, no hardlinks)
  snapshot        tracked files only (Dockerfile, compose.yaml, package.json, bun.lock,
                  tsconfig.json, src/, docker/, gui/, scripts/generate-compatibility-version.ts,
                  scripts/model-metadata.source.json)
  excluded        .env, credentials, homes, logs, build outputs, untracked files
  manifest        generated and verified locally before transfer
  transfer        incremental rsync of tracked files and the generated manifest
  verify          remote sha256sum manifest plus file-inventory count before promotion
  preserve        ${REMOTE_BASE} parent files, backups, compose override, credentials, volumes
  execution       run-remote is $([ "$RUN_REMOTE" -eq 1 ] && echo enabled || echo disabled)
  secrets         none generated or transferred; the admin token is never printed or copied
  no-op           make install and any Git write are never performed
EOF
}

# Run a command on the VPS with strict host-key and batch-mode verification.
remote_exec() {
  ssh -p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=yes \
    "$VPS_USER@$HOST" "$@"
}

# Stream one local file to a remote path over the same verified SSH session.
remote_upload() {
  local source="$1" destination="$2"
  ssh -p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=yes \
    "$VPS_USER@$HOST" "cat > '$destination'" < "$source"
}

# Prove the host key and authentication before creating any remote directory.
check_ssh() {
  remote_exec true || die "SSH to ${VPS_USER}@${HOST} failed host-key or authentication verification"
}

# Check the remote prerequisites and refuse unsafe destination paths before any rsync write.
# Every managed path must be a symlink-free child of the base, and source.previous must already
# be a real directory before promotion may replace it, so no rm -rf can leave the isolated base.
remote_preflight() {
  remote_exec "command -v rsync >/dev/null 2>&1" \
    || die "rsync is required on the VPS; install it there with: apt-get update && apt-get install -y rsync"
  remote_exec "command -v sha256sum >/dev/null 2>&1" \
    || die "sha256sum is required on the VPS for snapshot verification"
  remote_exec "set -e
    base='$REMOTE_BASE'
    source='$REMOTE_SOURCE_DIR'
    staging='$REMOTE_STAGING_DIR'
    previous='$REMOTE_SOURCE_PREVIOUS_DIR'
    # Walk every component upward and refuse a symlink anywhere in a managed path, so a later
    # rm -rf can never follow a link out of the operator's base directory.
    for path in \"\$base\" \"\$source\" \"\$staging\" \"\$previous\"; do
      probe=\"\$path\"
      while [ -n \"\$probe\" ] && [ \"\$probe\" != / ] && [ \"\$probe\" != . ]; do
        if [ -L \"\$probe\" ]; then echo \"refusing symlinked remote path: \$probe\" >&2; exit 1; fi
        probe=\$(dirname -- \"\$probe\")
      done
    done
    if [ -e \"\$base\" ] && [ ! -d \"\$base\" ]; then echo \"refusing non-directory remote base: \$base\" >&2; exit 1; fi
    install -d -m 0700 \"\$base\"
    for path in \"\$source\" \"\$staging\"; do
      if [ -L \"\$path\" ]; then echo \"refusing symlink remote path: \$path\" >&2; exit 1; fi
      if [ -e \"\$path\" ] && [ ! -d \"\$path\" ]; then echo \"refusing non-directory remote path: \$path\" >&2; exit 1; fi
    done
    if [ -L \"\$previous\" ]; then echo \"refusing symlink source.previous: \$previous\" >&2; exit 1; fi
    if [ -e \"\$previous\" ] && [ ! -d \"\$previous\" ]; then echo \"refusing non-directory source.previous: \$previous\" >&2; exit 1; fi
    if [ -e \"\$staging\" ] && find \"\$staging\" -type l -print -quit | grep -q .; then
      echo \"refusing staging tree that already contains a symlink: \$staging\" >&2; exit 1
    fi
    # A real active source keeps --copy-dest a valid basis on the first run; existing contents
    # are never modified here.
    install -d -m 0700 \"\$source\"
  " || die "remote preflight failed; no snapshot was transferred"
  log "remote preflight passed for ${REMOTE_BASE}"
}

# Mirror the staged snapshot into the isolated staging tree with rsync, using the active remote
# source as a --copy-dest basis (remote-local copies, never --link-dest hardlinks) so a repeat
# run transfers only changed bytes. `--delete` prunes stale entries only in the staging tree.
rsync_snapshot() {
  rsync -rlpt --checksum --delete --safe-links \
    --copy-dest="$REMOTE_SOURCE_DIR" \
    -e "ssh -p $SSH_PORT -o BatchMode=yes -o StrictHostKeyChecking=yes" \
    "$STAGING/" "$VPS_USER@$HOST:$REMOTE_STAGING_DIR/"
  remote_upload "$SCRIPT_DIR/deploy-ocx-vps.sh" "$REMOTE_SCRIPT"
  remote_exec "chmod 0700 '$REMOTE_SCRIPT'"
  log "mirrored the staged snapshot and deploy script"
}

# Verify the complete staged snapshot remotely against the independent checksum manifest and
# file inventory. A mismatch aborts before promotion, so the active source is never replaced.
verify_remote_snapshot() {
  local expected actual manifest_lines
  expected="$(wc -l < "$STAGING/.ocx-inventory" | tr -d ' ')"
  manifest_lines="$(wc -l < "$STAGING/.ocx-manifest.sha256" | tr -d ' ')"
  [ "$manifest_lines" = "$expected" ] \
    || die "local manifest/inventory disagree ($manifest_lines != $expected); refusing to transfer"
  remote_exec "cd '$REMOTE_STAGING_DIR' && sha256sum -c --quiet .ocx-manifest.sha256" \
    || die "remote staging checksum verification failed; the active source was not changed"
  # Exclude exactly the two metadata files, never an `.ocx-*` glob, so a tracked file sharing the
  # prefix cannot silently drop out of the count.
  actual="$(remote_exec "find '$REMOTE_STAGING_DIR' -type f ! -path '$REMOTE_STAGING_DIR/.ocx-manifest.sha256' ! -path '$REMOTE_STAGING_DIR/.ocx-inventory' | wc -l" | tr -d ' ')"
  [ "$actual" = "$expected" ] \
    || die "remote staging file inventory mismatch ($actual != $expected); the active source was not changed"
  log "remote staging verified: $actual files match the local snapshot"
}

# Promote the verified staging tree to the active source, keeping the previous active tree as
# source.previous. Every path used by rm -rf is re-checked as a real directory first, so the
# removal can never follow a symlink or target anything outside the isolated base.
promote_snapshot() {
  local previous="$REMOTE_SOURCE_PREVIOUS_DIR"
  remote_exec "set -e
    if [ -L '$previous' ]; then echo 'refusing symlink source.previous at promotion: $previous' >&2; exit 1; fi
    if [ -e '$previous' ] && [ ! -d '$previous' ]; then echo 'refusing non-directory source.previous at promotion: $previous' >&2; exit 1; fi
    if [ -e '$previous' ]; then rm -rf -- '$previous'; fi
    if [ -e '$REMOTE_SOURCE_DIR' ]; then
      if [ -L '$REMOTE_SOURCE_DIR' ] || [ ! -d '$REMOTE_SOURCE_DIR' ]; then
        echo 'refusing unsafe active source at promotion: $REMOTE_SOURCE_DIR' >&2; exit 1
      fi
      mv '$REMOTE_SOURCE_DIR' '$previous'
    fi
    if ! mv '$REMOTE_STAGING_DIR' '$REMOTE_SOURCE_DIR'; then
      if [ -e '$previous' ]; then mv '$previous' '$REMOTE_SOURCE_DIR'; fi
      echo 'promotion failed; restored the previous active source' >&2
      exit 1
    fi
  " || die "could not promote the verified snapshot; the previous active source was restored"
  log "promoted the verified snapshot to ${REMOTE_SOURCE_DIR}"
}

# Print the exact, private way to read the admin token on the VPS for the dashboard sign-in form.
print_admin_token_guidance() {
  log "the dashboard at https://${DASHBOARD_DOMAIN}/ presents the OpenCodeX admin-token sign-in form."
  log "read the token in a human-operated terminal on the VPS and paste it into the form:"
  log "  docker compose -p $PROJECT_NAME -f $REMOTE_SOURCE_DIR/compose.yaml -f $REMOTE_COMPOSE_OVERRIDE exec hub cat /home/bun/.opencodex/admin-api-token"
  log "an Account label you type in the form is only a browser/password-manager label for that token."
  log "a one-time 'ocx gui pair' code pairs a GUI browser session and is not accepted by this admin-token form."
  log "keep the token private: never print it or paste it into logs, chat, or shell history."
}

# Verify the public dashboard from this machine without any edge credential. No secret is
# involved: the dashboard must load directly, reach OpenCodeX's pairing route for enrollment,
# and leave /api/* to OpenCodeX management authorization and /v1/* to Caddy's dashboard 404.
verify_public_dashboard() {
  local base="https://${DASHBOARD_DOMAIN}" origin="https://${DASHBOARD_DOMAIN}" code headers

  # The dashboard root loads without a Caddy Basic Auth challenge.
  headers="$(curl -sS -D - -o /dev/null --max-time 20 "$base/" || true)"
  code="$(printf '%s\n' "$headers" | awk 'NR==1{print $2}')"
  [ "$code" = "200" ] || die "dashboard root returned ${code:-no response}, expected 200 without Basic Auth"
  if printf '%s\n' "$headers" | grep -qi '^www-authenticate:[[:space:]]*basic'; then
    die "dashboard root still emits a Caddy Basic Auth challenge (WWW-Authenticate: Basic)"
  fi
  log "dashboard root returned 200 with no Caddy Basic Auth challenge"

  # No data-plane route is proxied on the dashboard host.
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$base/v1/models" || true)"
  [ "$code" = "404" ] || die "/v1/models on the dashboard host returned $code, expected 404"
  log "the dashboard host blocks /v1/*"

  # OpenCodeX's pairing route is reached: a malformed body is its own 400. This proves routing
  # only; browser sign-in uses the admin token, not a pairing code.
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    -X POST -H "Origin: $origin" -H 'content-type: application/json' --data '{}' "$base/opencodex-session" || true)"
  [ "$code" = "400" ] || die "POST /opencodex-session returned $code, expected 400 from OpenCodeX's pairing route"
  log "requests reach OpenCodeX's pairing route"

  # OpenCodeX's own management authorization still gates /api/*.
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$base/api/config" || true)"
  [ "$code" = "401" ] || die "/api/config returned $code, expected 401 from OpenCodeX management auth"
  log "OpenCodeX management authorization gates /api/*"
}

# Parse flags before performing any work, then run the copy. main is only invoked when the
# script is executed, so tests can source the functions without side effects.
main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --run-remote) RUN_REMOTE=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "unknown argument: $1" ;;
    esac
    shift
  done

  parse_env_file
  derive_dashboard_domain
  validate_target
  check_local_tools
  detect_symlinks
  stage_snapshot
  print_plan

  if [ "$DRY_RUN" -eq 1 ]; then
    log "dry run: snapshot staged and verified; no remote access performed"
    exit 0
  fi

  check_ssh
  remote_preflight
  rsync_snapshot
  verify_remote_snapshot
  promote_snapshot

  if [ "$RUN_REMOTE" -eq 1 ]; then
    log "executing the remote deploy script for ${DOMAIN} and ${DASHBOARD_DOMAIN} at ${HOST}"
    remote_exec "OCX_DEPLOY_ROOT='$REMOTE_BASE' '$REMOTE_SCRIPT' --target-ip '$HOST' --domain '$DOMAIN' --dashboard-domain '$DASHBOARD_DOMAIN'"
    verify_public_dashboard
  else
    log "run the remote deploy later with:"
    log "  ssh -p $SSH_PORT ${VPS_USER}@${HOST} 'OCX_DEPLOY_ROOT=$REMOTE_BASE $REMOTE_SCRIPT --target-ip $HOST --domain $DOMAIN --dashboard-domain $DASHBOARD_DOMAIN'"
    print_admin_token_guidance
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
