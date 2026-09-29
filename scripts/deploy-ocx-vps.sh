#!/usr/bin/env bash
# Deploy opencodex on this otherwise empty VPS with a dedicated Caddy container.
# Runs on the VPS only: it aborts on any address, DNS, OS, resource, port, or conflicting Compose
# state before making a change. Caddy serves two hostnames: the data API hostname is data-only,
# and the separate dashboard hostname is gated by OpenCodeX's own admin-token/session
# authorization (there is no edge Basic Auth). The hub is published only on 127.0.0.1.
set -euo pipefail

# Absolute location of this script; the default deploy root is its own directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# All locations and names are explicit and overridable so nothing is guessed silently.
DEPLOY_ROOT="${OCX_DEPLOY_ROOT:-$SCRIPT_DIR}"
SOURCE_DIR="${OCX_SOURCE_DIR:-$DEPLOY_ROOT/source}"
PROJECT_NAME="${OCX_PROJECT_NAME:-opencodex-vps}"
HOST_PORT="${OCX_HOST_PORT:-10100}"
CONTAINER_PORT="${OCX_CONTAINER_PORT:-10100}"
INTERNAL_NETWORK="${OCX_INTERNAL_NETWORK:-ocx-internal}"
CADDY_IMAGE="${OCX_CADDY_IMAGE:-caddy:2.8-alpine}"
COMPOSE_OVERRIDE="${DEPLOY_ROOT}/compose.vps.yaml"
CADDYFILE="${DEPLOY_ROOT}/Caddyfile"
BACKUP_DIR="${DEPLOY_ROOT}/backups"
MIN_FREE_DISK_MB="${OCX_MIN_FREE_DISK_MB:-2048}"
MIN_FREE_MEM_MB="${OCX_MIN_FREE_MEM_MB:-1024}"
MIN_UBUNTU_MAJOR="${OCX_MIN_UBUNTU_MAJOR:-22}"
HEALTH_TIMEOUT="${OCX_HEALTH_TIMEOUT:-90}"

# Deployment target, supplied as explicit non-secret arguments by the copy script.
TARGET_IP="${OCX_VPS_HOST:-}"
DOMAIN="${OCX_DOMAIN:-}"
# Separate public dashboard hostname. Caddy only terminates TLS for it; OpenCodeX's admin-token
# sign-in and session authorization is the only gate. A stale Basic Auth hash file may still
# exist on an upgraded host and is deliberately neither read, printed, nor deleted here.
DASHBOARD_DOMAIN="${OCX_DASHBOARD_DOMAIN:-}"

# Execution modes: dry run runs read-only preflight, print-plan only prints.
DRY_RUN=0
PRINT_PLAN_ONLY=0

# Set when a previous Caddyfile backup exists so an early failure can restore it.
CADDY_BACKUP=""
# Set by check_caddyfile_target to "644" when a pre-existing Caddyfile is still legacy 0644
# and needs the in-place 0600 migration; empty when it is already 0600 or absent.
CADDYFILE_LEGACY_MODE=""
# Flipped once the new configuration is live; until then the exit handler restores the backup.
CADDY_COMMITTED=0
# Mode-0600 curl config holding a data-plane key; removed by the exit handler on every path.
AUTH_HEADER_FILE=""

# Write a progress line to stderr so stdout stays available for the plan.
log() { printf '[deploy-ocx-vps] %s\n' "$*" >&2; }

# Abort with an actionable message and a non-zero exit status.
die() { printf '[deploy-ocx-vps] ERROR: %s\n' "$*" >&2; exit 1; }

# Print the accepted flags and the meaning of each override.
usage() {
  cat >&2 <<'EOF'
Usage: deploy-ocx-vps.sh --target-ip <ipv4> --domain <hostname> --dashboard-domain <hostname> [--dry-run] [--print-plan]

Runs on the VPS. Verifies Ubuntu, package availability, the source snapshot, the
host address, both DNS names, resources, and ports, installs Ubuntu's docker.io
and docker-compose-v2 only when missing, then builds and starts opencodex with a
dedicated Caddy container that terminates HTTPS for the data API hostname and the
admin-token-gated dashboard hostname.

Flags:
  --target-ip <ipv4>         Required public IPv4 this VPS must own and both hostnames resolve to.
  --domain <hostname>        Required public data API hostname served by Caddy.
  --dashboard-domain <host>  Required separate public dashboard hostname.
  --dry-run                  Run read-only preflight checks, print the plan, and make no changes.
  --print-plan               Print the plan only; perform no environment access.
  -h, --help                 Show this help.

Overrides:
  OCX_DEPLOY_ROOT          Deploy root holding source/ and the generated files (default script dir).
  OCX_SOURCE_DIR           Verified snapshot directory (default DEPLOY_ROOT/source).
  OCX_PROJECT_NAME         Compose project name (default opencodex-vps).
  OCX_HOST_PORT            Loopback host port for the hub (default 10100).
  OCX_INTERNAL_NETWORK     Private Compose network (default ocx-internal).
  OCX_CADDY_IMAGE          Caddy image (default caddy:2.8-alpine).
  OCX_DASHBOARD_DOMAIN     Dashboard hostname when it is not passed as a flag.
  OCX_EXPECTED_PUBLIC_IP   Deprecated alias for --target-ip, kept for compatibility.
EOF
}

# Fail early when a required host tool is missing, naming the tool.
require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "required tool not found on the VPS: $1"
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

# Reject names and paths that would corrupt the generated Compose file or Caddy block.
validate_config() {
  case "$DEPLOY_ROOT" in /*) : ;; *) die "OCX_DEPLOY_ROOT must be absolute: $DEPLOY_ROOT" ;; esac
  case "$SOURCE_DIR" in /*) : ;; *) die "OCX_SOURCE_DIR must be absolute: $SOURCE_DIR" ;; esac
  case "$HOST_PORT" in ''|*[!0-9]*) die "OCX_HOST_PORT must be numeric: $HOST_PORT" ;; esac
  case "$CONTAINER_PORT" in ''|*[!0-9]*) die "OCX_CONTAINER_PORT must be numeric: $CONTAINER_PORT" ;; esac
  validate_ipv4 "$TARGET_IP" || die "--target-ip must be a valid IPv4 address"
  validate_hostname "$DOMAIN" || die "--domain must be a valid public hostname"
  validate_hostname "$DASHBOARD_DOMAIN" || die "--dashboard-domain must be a valid public hostname"
  [ "$DASHBOARD_DOMAIN" != "$DOMAIN" ] \
    || die "--dashboard-domain must differ from --domain so the dashboard is not exposed on the API host"
  case "$PROJECT_NAME" in
    ''|*[!A-Za-z0-9_.-]*) die "OCX_PROJECT_NAME is not a safe Compose project name: $PROJECT_NAME" ;;
  esac
  case "$INTERNAL_NETWORK" in
    ''|*[!A-Za-z0-9_.-]*) die "OCX_INTERNAL_NETWORK is not a safe network name: $INTERNAL_NETWORK" ;;
  esac
  case "$CADDY_IMAGE" in
    ''|*[!A-Za-z0-9._/@:-]*) die "OCX_CADDY_IMAGE is not a safe image reference: $CADDY_IMAGE" ;;
  esac
}

# Docker Compose always runs as this isolated project with the generated network override.
compose() {
  docker compose -p "$PROJECT_NAME" -f "$SOURCE_DIR/compose.yaml" -f "$COMPOSE_OVERRIDE" "$@"
}

# Confirm this is an Ubuntu release new enough to ship docker-compose-v2.
check_os_version() {
  local os_id="" version_id="" major
  if [ -r /etc/os-release ]; then
    os_id="$(sed -n 's/^ID=//p' /etc/os-release | head -n1 | tr -d '"')"
    version_id="$(sed -n 's/^VERSION_ID=//p' /etc/os-release | head -n1 | tr -d '"')"
  fi
  [ "$os_id" = "ubuntu" ] || die "this deployment targets Ubuntu; detected ID='${os_id:-unknown}'"
  major="${version_id%%.*}"
  case "$major" in ''|*[!0-9]*) die "could not parse Ubuntu VERSION_ID='$version_id'" ;; esac
  [ "$major" -ge "$MIN_UBUNTU_MAJOR" ] \
    || die "Ubuntu $version_id is too old; docker-compose-v2 requires ${MIN_UBUNTU_MAJOR}.04 or newer"
  log "detected Ubuntu $version_id"
}

# Report whether a package has an install candidate in the currently configured repositories.
apt_has_candidate() {
  apt-cache policy "$1" 2>/dev/null | grep -Eq 'Candidate: [0-9]'
}

# True when at least one APT package index file is present, so candidates can be trusted.
apt_lists_present() {
  find /var/lib/apt/lists -maxdepth 1 -type f -name '*Packages*' -print -quit 2>/dev/null | grep -q .
}

# Verify Docker and Compose can be installed from Ubuntu's repositories, without adding any
# third-party repository. A missing index is deferred to the install step's apt-get update.
check_package_availability() {
  require_tool apt-get
  require_tool apt-cache
  apt_lists_present || { log "APT indexes are absent; the install step will refresh them"; return 0; }
  if ! command -v docker >/dev/null 2>&1; then
    apt_has_candidate docker.io \
      || die "the docker.io package has no candidate in the configured Ubuntu repositories"
  fi
  if ! docker compose version >/dev/null 2>&1; then
    apt_has_candidate docker-compose-v2 \
      || die "the docker-compose-v2 package has no candidate in the configured Ubuntu repositories"
  fi
}

# Verify docker, the compose plugin, and daemon reachability.
preflight_docker() {
  require_tool docker
  docker compose version >/dev/null 2>&1 || die "the docker compose v2 plugin is not available"
  docker info >/dev/null 2>&1 || die "the docker daemon is not reachable"
}

# Confirm the requested target is one of this host's global IPv4 addresses. No third-party
# address lookup is made; the interface list is the authority.
check_target_address() {
  local addresses
  if command -v ip >/dev/null 2>&1; then
    addresses="$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
  else
    addresses="$(hostname -I 2>/dev/null | tr ' ' '\n')"
  fi
  printf '%s\n' "$addresses" | grep -qx "$TARGET_IP" \
    || die "requested target $TARGET_IP is not an address on this host; refusing to deploy"
  log "the target address $TARGET_IP belongs to this host"
}

# Resolve one public hostname and require it to point at the requested target address.
check_dns_one() {
  local host="$1" label="$2" resolved
  resolved="$(getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u | head -n1)"
  [ -n "$resolved" ] || die "DNS for the $label hostname $host does not resolve; create the A record for $TARGET_IP first"
  [ "$resolved" = "$TARGET_IP" ] \
    || die "DNS for the $label hostname $host resolves to $resolved, not $TARGET_IP; refusing to deploy"
  log "DNS for the $label hostname $host resolves to the requested target"
}

# Require BOTH public hostnames to point at the requested target before any install.
check_dns() {
  check_dns_one "$DOMAIN" "data API"
  check_dns_one "$DASHBOARD_DOMAIN" "dashboard"
}

# Refuse to proceed when available memory or disk is below the configured floor.
check_resources() {
  local mem_mb disk_mb
  mem_mb="$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
  disk_mb="$(df -Pk "$DEPLOY_ROOT" | awk 'NR==2{printf "%d", $4/1024}')"
  [ "${mem_mb:-0}" -ge "$MIN_FREE_MEM_MB" ] || die "insufficient available memory: ${mem_mb}MB < ${MIN_FREE_MEM_MB}MB"
  [ "${disk_mb:-0}" -ge "$MIN_FREE_DISK_MB" ] || die "insufficient free disk: ${disk_mb}MB < ${MIN_FREE_DISK_MB}MB"
  log "resources available: ${mem_mb}MB memory, ${disk_mb}MB disk"
}

# True when any process, including our own project, is listening on the port.
port_has_listener() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    [ -n "$(ss -H -ltn "sport = :$port" 2>/dev/null || true)" ] && return 0
  elif command -v netstat >/dev/null 2>&1; then
    [ -n "$(netstat -ltn 2>/dev/null | awk -v p=":$port" '$4 ~ p {print}')" ] && return 0
  elif (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    return 0
  fi
  return 1
}

# Refuse a required port unless it is free or already published by this project.
check_port() {
  local port="$1" owners
  port_has_listener "$port" || return 0
  owners="$(docker ps --filter "publish=$port" \
    --filter "label=com.docker.compose.project=$PROJECT_NAME" --format '{{.ID}}' 2>/dev/null || true)"
  [ -n "$owners" ] || die "host port $port is already in use by another process; refusing to deploy"
}

# Require the ports Caddy and the loopback hub need before installing anything.
check_required_ports() {
  check_port 80
  check_port 443
  check_port "$HOST_PORT"
  log "ports 80, 443, and $HOST_PORT are free or owned by this project"
}

# Require the files the Docker build reads and the bootstrap script, before touching anything.
check_source() {
  local f
  for f in Dockerfile compose.yaml package.json bun.lock tsconfig.json \
    docker/verify-compatibility.ts docker/bootstrap-token.ts; do
    [ -f "$SOURCE_DIR/$f" ] || die "source snapshot is incomplete: missing $SOURCE_DIR/$f"
  done
}

# Refuse to proceed when another Compose project already serves ports 80/443. The port
# listener check below catches any foreign process; this names the conflicting project first.
check_compose_conflicts() {
  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || return 0
  local port foreign
  for port in 80 443; do
    foreign="$(docker ps --filter "publish=$port" --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null \
      | grep -v -x -e "$PROJECT_NAME" -e '' | sort -u | tr '\n' ' ' || true)"
    [ -z "$foreign" ] \
      || die "host port $port is already served by another Compose project (${foreign% }); refusing to deploy"
  done
  log "no conflicting Compose project owns ports 80 or 443"
}

# Run every read-only check in order; any mismatch aborts with an actionable message.
# Nothing below writes host or container state, so --dry-run makes no changes.
run_preflight() {
  check_os_version
  check_package_availability
  check_source
  # Reject an unsafe pre-existing generated Caddyfile before any install or write occurs.
  check_caddyfile_target
  check_target_address
  check_dns
  check_resources
  check_compose_conflicts
  check_required_ports
}

# Install Docker Engine and the Compose v2 plugin from Ubuntu's repositories only when missing.
# No external repository or curl pipeline is used, and the Docker service is started if present.
install_and_start_docker() {
  local packages=()
  if ! command -v docker >/dev/null 2>&1; then
    packages+=(docker.io)
  fi
  if ! docker compose version >/dev/null 2>&1; then
    packages+=(docker-compose-v2)
  fi
  if [ "${#packages[@]}" -gt 0 ]; then
    log "installing Ubuntu packages: ${packages[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
  else
    log "docker and the compose v2 plugin are already installed"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || true
  fi
  if command -v service >/dev/null 2>&1; then
    service docker start >/dev/null 2>&1 || true
  fi
}

# Write the generated Compose override atomically so a partial write cannot corrupt Compose.
write_compose_override() {
  mkdir -p "$DEPLOY_ROOT"
  local tmp
  tmp="$(mktemp "$DEPLOY_ROOT/.compose.vps.XXXXXX")"
  cat > "$tmp" <<EOF
# Generated by deploy-ocx-vps.sh; do not edit. Re-runnable and safe to delete.
services:
  hub:
    networks:
      - ${INTERNAL_NETWORK}
  caddy:
    image: ${CADDY_IMAGE}
    restart: unless-stopped
    read_only: true
    depends_on:
      hub:
        condition: service_healthy
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ${CADDYFILE}:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
    tmpfs:
      - /tmp
    networks:
      - ${INTERNAL_NETWORK}
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
networks:
  ${INTERNAL_NETWORK}:
    driver: bridge
volumes:
  caddy-data:
  caddy-config:
EOF
  chmod 0600 "$tmp"
  mv -f "$tmp" "$COMPOSE_OVERRIDE"
}

# Fail closed unless an existing generated Caddyfile is safe to truncate in place: never a
# symlink, a regular file, owned by root, and mode 0600 or the exact legacy 0644 that is
# migrated below. Absent is allowed because it is created below; the mode/owner are re-checked
# on every rerun so a loosened file cannot persist. Read-only: records the legacy mode in
# CADDYFILE_LEGACY_MODE for the caller to migrate, and never changes the file itself.
check_caddyfile_target() {
  CADDYFILE_LEGACY_MODE=""
  # -e misses a broken symlink, so the -L fallback still routes it into the symlink rejection.
  [ -e "$CADDYFILE" ] || [ -L "$CADDYFILE" ] || return 0
  [ ! -L "$CADDYFILE" ] || die "existing Caddyfile must not be a symlink: $CADDYFILE"
  [ -f "$CADDYFILE" ] || die "existing Caddyfile is not a regular file: $CADDYFILE"
  local perms owner
  perms="$(stat -c '%a' "$CADDYFILE" 2>/dev/null || stat -f '%Lp' "$CADDYFILE" 2>/dev/null || echo '')"
  owner="$(stat -c '%u' "$CADDYFILE" 2>/dev/null || stat -f '%u' "$CADDYFILE" 2>/dev/null || echo '')"
  # Mode is checked before owner so either unsafe property reports its own actionable reason.
  case "$perms" in
    600) : ;;
    644)
      # Recognized legacy mode; the actual deploy migrates it in place. Report on every
      # caller path, including dry-run, without touching the file.
      CADDYFILE_LEGACY_MODE="$perms"
      log "existing Caddyfile is legacy mode 0644; it will be migrated to 0600 before rewriting" ;;
    *) die "existing Caddyfile must be mode 0600 or legacy 0644 (found '${perms:-unknown}'); run: chmod 0600 '$CADDYFILE'" ;;
  esac
  [ "$owner" = "0" ] \
    || die "existing Caddyfile must be owned by root (found uid '${owner:-unknown}'): $CADDYFILE"
}

# Write the generated Caddyfile in place so the bind-mounted inode stays valid, after saving a
# timestamped backup the exit handler can restore. The dashboard site carries no edge Basic Auth;
# OpenCodeX's admin-token sign-in and session authorization is the only gate. The file is created
# and re-chmodded 0600 so the container's read-only bind mount never sees umask-derived bits.
write_caddyfile() {
  mkdir -p "$DEPLOY_ROOT"
  # Validate any pre-existing target before generating content, so an unsafe file fails closed.
  check_caddyfile_target
  # A recognized legacy 0644 file is migrated in place before any content is written. chmod keeps
  # the inode the container is bound to, and the target is revalidated as 0600 afterwards.
  if [ -n "$CADDYFILE_LEGACY_MODE" ]; then
    log "migrating existing Caddyfile from mode $CADDYFILE_LEGACY_MODE to 0600 in place"
    chmod 0600 "$CADDYFILE"
    CADDYFILE_LEGACY_MODE=""
    check_caddyfile_target
  fi
  local tmp
  tmp="$(mktemp "$DEPLOY_ROOT/.Caddyfile.XXXXXX")"
  cat > "$tmp" <<EOF
# Generated by deploy-ocx-vps.sh; do not edit. Two sites: data-only API and admin-token dashboard.
# Data API site: only the inference and health paths; every other path is a 404.
${DOMAIN} {
	encode zstd gzip
	@data path /v1/* /healthz /readyz
	handle @data {
		reverse_proxy hub:${CONTAINER_PORT} {
			# The hub trusts identity headers only on its loopback management listener,
			# so strip them at the public edge as defence in depth.
			header_up -Tailscale-User-Login
			header_up -Tailscale-User-Name
			header_up -Tailscale-User-Profile-Pic
		}
	}
	handle {
		respond 404
	}
}

# Dashboard site: no edge Basic Auth. Caddy terminates TLS and OpenCodeX's own admin-token
# sign-in and session authorization inside the hub is the only gate. The API host never serves
# these paths.
${DASHBOARD_DOMAIN} {
	encode zstd gzip
	# No data-plane route is proxied on the dashboard host.
	@dashboard_data path /v1/*
	handle @dashboard_data {
		respond 404
	}
	reverse_proxy hub:${CONTAINER_PORT} {
		# Preserve the real Host and Origin that the session and pairing routes validate.
		header_up Host {http.request.host}
		# Drop any client-supplied Authorization and spoofable identity headers before proxying.
		header_up -Authorization
		header_up -Tailscale-User-Login
		header_up -Tailscale-User-Name
		header_up -Tailscale-User-Profile-Pic
	}
}
EOF
  chmod 0600 "$tmp"
  # An unchanged rerun must not churn the file or pile up backups.
  if [ -f "$CADDYFILE" ] && cmp -s "$tmp" "$CADDYFILE"; then
    rm -f "$tmp"
    return 0
  fi
  if [ -f "$CADDYFILE" ]; then
    mkdir -p "$BACKUP_DIR"
    CADDY_BACKUP="$BACKUP_DIR/Caddyfile.$(date +%Y%m%d%H%M%S).bak"
    cp -p "$CADDYFILE" "$CADDY_BACKUP"
  else
    # Create the path 0600 despite umask 002/022; never mv it, so the bind-mounted inode is stable.
    (umask 077; : > "$CADDYFILE")
  fi
  # Truncating the existing path keeps the same inode the container is bound to.
  cat "$tmp" > "$CADDYFILE"
  # Re-assert 0600 after the write so a rerun cannot inherit looser mode bits.
  chmod 0600 "$CADDYFILE"
  if ! cmp -s "$tmp" "$CADDYFILE"; then
    rm -f "$tmp"
    die "the Caddyfile write did not complete; restoring the previous Caddyfile"
  fi
  rm -f "$tmp"
}

# Restore the saved Caddyfile in place and reload, leaving the running service consistent.
rollback_caddy() {
  if [ -z "$CADDY_BACKUP" ] || [ ! -f "$CADDY_BACKUP" ]; then
    return 0
  fi
  cat "$CADDY_BACKUP" > "$CADDYFILE"
  if compose ps --status running --services 2>/dev/null | grep -qx caddy; then
    compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || true
  fi
  log "restored the previous Caddyfile"
  CADDY_BACKUP=""
}

# Exit handler: delete transient secret files and restore a half-applied Caddy edit.
on_exit() {
  [ -z "$AUTH_HEADER_FILE" ] || rm -f "$AUTH_HEADER_FILE"
  [ "$CADDY_COMMITTED" -eq 1 ] || rollback_caddy
}

# Ask a one-off Caddy container to validate the generated configuration before it goes live.
validate_caddyfile() {
  compose run --rm --no-deps -T --entrypoint caddy caddy \
    validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
}

# Generate a data-plane token locally without printing it and without touching Compose config.
generate_data_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

# Bootstrap the data token once; reruns keep the existing state-volume token untouched.
ensure_data_token() {
  if compose run --rm -T --no-deps --entrypoint sh hub \
    -c 'test -s /home/bun/.opencodex/service-api-token' >/dev/null 2>&1; then
    log "data-plane token already present in the state volume; leaving it unchanged"
    return 0
  fi
  local token
  token="$(generate_data_token)"
  printf '%s\n' "$token" | compose run --rm -T --no-deps hub bun docker/bootstrap-token.ts >/dev/null
  unset token
  log "bootstrapped a fresh data-plane token into the state volume"
}

# Stop the hub and point hub.managementPublicOrigin at the dashboard origin, keeping every
# other persisted setting. A single one-off container writes config; the hub is stopped first
# so only one process ever touches the state volume.
ensure_hub_origin_config() {
  local origin="https://${DASHBOARD_DOMAIN}" result script
  # A quoted heredoc keeps the remote script's own $ expansions for the container's shell.
  script="$(cat <<'REMOTE'
set -e
origin="$1"
current="$(bun run src/cli/index.ts config get hub.managementPublicOrigin 2>/dev/null || true)"
if [ "$current" = "$origin" ]; then echo unchanged; exit 0; fi
if ! bun run src/cli/index.ts config get hub >/dev/null 2>&1; then
  bun run src/cli/index.ts config set hub "{}" >/dev/null
fi
bun run src/cli/index.ts config set hub.managementPublicOrigin "$origin" >/dev/null
echo updated
REMOTE
)"
  compose stop hub >/dev/null 2>&1 || true
  result="$(compose run --rm -T --no-deps --entrypoint sh hub -c "$script" sh "$origin")"
  log "hub.managementPublicOrigin is ${result:-unchanged} for https://${DASHBOARD_DOMAIN}"
}

# Build the image, bootstrap state once, and start the isolated project with Caddy.
deploy_compose() {
  write_compose_override
  write_caddyfile
  export OPENCODEX_BIND_ADDRESS=127.0.0.1
  export OPENCODEX_PORT="$HOST_PORT"
  log "validating the generated Caddy configuration"
  validate_caddyfile || die "Caddy rejected the generated configuration; nothing was started"
  log "building the hub image (the build also validates the compatibility manifest)"
  compose build hub
  ensure_hub_origin_config
  ensure_data_token
  log "starting project $PROJECT_NAME"
  compose up -d
  # A rerun with an edited Caddyfile keeps the mounted inode; reload makes it active.
  compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null \
    || die "Caddy failed to reload the validated configuration"
  CADDY_COMMITTED=1
  log "project $PROJECT_NAME is running with a loopback hub and two Caddy sites"
}

# Poll the loopback health endpoint until it answers or the timeout expires.
wait_for_health() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if curl -fsS --max-time 3 "http://127.0.0.1:$HOST_PORT/healthz" >/dev/null 2>&1; then
      log "hub answered /healthz on 127.0.0.1:$HOST_PORT"
      return 0
    fi
    sleep 2
  done
  die "hub did not answer /healthz on 127.0.0.1:$HOST_PORT within ${HEALTH_TIMEOUT}s"
}

# Poll both public HTTPS endpoints until each certificate is issued and the site answers.
wait_for_https() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT)) domain code
  local pending=("$DOMAIN" "$DASHBOARD_DOMAIN")
  while [ "$SECONDS" -lt "$deadline" ] && [ "${#pending[@]}" -gt 0 ]; do
    local next=()
    for domain in "${pending[@]}"; do
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "https://$domain/" || true)"
      if [ -n "$code" ] && [ "$code" != "000" ]; then
        log "https://$domain answered (HTTP $code)"
      else
        next+=("$domain")
      fi
    done
    pending=("${next[@]}")
    [ "${#pending[@]}" -gt 0 ] || return 0
    sleep 2
  done
  die "HTTPS did not answer for: ${pending[*]}; check DNS and certificate issuance"
}

# Prove the data host refuses anonymous data and never exposes the dashboard or /api/*, and that
# the dashboard host serves its GUI without a Caddy Basic Auth challenge while still deferring
# /api/* to OpenCodeX's management authorization and blocking /v1/*.
check_public_boundary() {
  local code headers
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/v1/models" || true)"
  case "$code" in
    401|403) log "unauthenticated /v1/models correctly refused ($code)" ;;
    *) die "unauthenticated /v1/models returned $code, expected 401/403" ;;
  esac
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/" || true)"
  [ "$code" = "404" ] || die "dashboard root on $DOMAIN returned $code, expected 404"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/api/config" || true)"
  [ "$code" = "404" ] || die "management /api/config on $DOMAIN returned $code, expected 404"
  log "dashboard and /api/* are not exposed on $DOMAIN"

  # The dashboard root loads directly: no Caddy Basic Auth challenge may be present.
  headers="$(curl -sS -D - -o /dev/null --max-time 10 "https://$DASHBOARD_DOMAIN/" || true)"
  code="$(printf '%s\n' "$headers" | awk 'NR==1{print $2}')"
  [ "$code" = "200" ] || die "dashboard root on $DASHBOARD_DOMAIN returned ${code:-no response}, expected 200"
  if printf '%s\n' "$headers" | grep -qi '^www-authenticate:[[:space:]]*basic'; then
    die "dashboard root on $DASHBOARD_DOMAIN still emits a Caddy Basic Auth challenge"
  fi
  log "the dashboard host serves its GUI without a Basic Auth challenge"

  # The pairing route is reachable: a malformed body is OpenCodeX's own 400, not Caddy's 401.
  # This proves routing only; browser sign-in uses the admin token, not a pairing code.
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -X POST -H "Origin: https://$DASHBOARD_DOMAIN" -H 'content-type: application/json' --data '{}' \
    "https://$DASHBOARD_DOMAIN/opencodex-session" || true)"
  [ "$code" = "400" ] || die "POST /opencodex-session on $DASHBOARD_DOMAIN returned $code, expected 400 from OpenCodeX's pairing route"
  log "the dashboard host reaches OpenCodeX's pairing route"

  # OpenCodeX's management authorization still gates /api/* on the dashboard host.
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$DASHBOARD_DOMAIN/api/config" || true)"
  [ "$code" = "401" ] || die "/api/config on $DASHBOARD_DOMAIN returned $code, expected 401 from OpenCodeX management auth"
  log "OpenCodeX management authorization gates /api/* on the dashboard host"

  # No data-plane route is proxied on the dashboard host.
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$DASHBOARD_DOMAIN/v1/models" || true)"
  [ "$code" = "404" ] || die "/v1/models on $DASHBOARD_DOMAIN returned $code, expected 404"
  log "the dashboard host blocks /v1/*"
}

# Read the data token from the container without printing it, then probe authenticated readiness.
check_authenticated_catalog() {
  local token code
  token="$(compose run --rm -T --no-deps --entrypoint cat hub /home/bun/.opencodex/service-api-token 2>/dev/null | tr -d '\r\n')"
  [ -n "$token" ] || die "could not read the data-plane token from the state volume"
  AUTH_HEADER_FILE="$(mktemp)"; chmod 0600 "$AUTH_HEADER_FILE"
  printf 'header = "x-opencodex-api-key: %s"\n' "$token" > "$AUTH_HEADER_FILE"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -K "$AUTH_HEADER_FILE" "https://$DOMAIN/v1/models" || true)"
  rm -f "$AUTH_HEADER_FILE"; AUTH_HEADER_FILE=""; unset token
  if [ "$code" = "200" ]; then
    log "authenticated catalog readiness is 200 (a provider and model are configured)"
  else
    log "authenticated /v1/models returned $code; a provider and model still need configuration"
  fi
}

# Print the manual steps that remain, including the public dashboard sign-in and per-client key flow.
print_next_steps() {
  cat >&2 <<EOF
Next steps (manual, never automated by this script):
  1. Configure a provider and model (dashboard or management API) before expecting inference.
  2. Open the public dashboard at https://$DASHBOARD_DOMAIN/. There is no Basic Auth password:
     Caddy terminates TLS and OpenCodeX's own admin-token sign-in and session authorization is
     the only gate. The dashboard is never served on the data API hostname.
  3. The sign-in form asks for the OpenCodeX admin token. An Account label you type there is only
     a browser/password-manager label for that token, not a separate credential. Read the token
     in a human-operated terminal on the VPS and paste the value into the form:
       docker compose -p $PROJECT_NAME -f "$SOURCE_DIR/compose.yaml" -f "$COMPOSE_OVERRIDE" exec hub \\
         cat /home/bun/.opencodex/admin-api-token
     Treat the token as private: never print it or paste it into logs, chat, or shell history.
     A one-time 'ocx gui pair' code is for machine enrollment and is not accepted by this form.
     The GUI never stores the token in localStorage or sessionStorage; whether your password
     manager saves it is your browser's decision.
  4. Give each data client its own revocable key, never the shared bootstrap token. In a
     human-operated terminal on the VPS, run:
       docker compose -p $PROJECT_NAME -f "$SOURCE_DIR/compose.yaml" -f "$COMPOSE_OVERRIDE" exec hub \\
         bun run src/cli/index.ts access key create <client-name>
     The key is shown once; configure the client from that terminal and keep it out of shell
     history, chat transcripts, and logs. Data calls use x-opencodex-api-key at https://$DOMAIN/v1.
  5. To invite another opencodex machine, use Remote Workspace pairing in the dashboard or
     the hub command ocx hub invite in a human-operated terminal; treat the printed command
     as a secret.
Provider credentials stay on the VPS. Inference is not claimed ready until a real model
request succeeds.
EOF
}

# Describe every intended effect without touching the environment.
print_plan() {
  cat >&2 <<EOF
Plan:
  target          $TARGET_IP
  data API        https://$DOMAIN (data-only: /v1/*, /healthz, /readyz)
  dashboard       https://$DASHBOARD_DOMAIN (OpenCodeX admin-token sign-in; no edge Basic Auth)
  project         $PROJECT_NAME in $SOURCE_DIR
  publication     hub only on 127.0.0.1:$HOST_PORT; Caddy on 80 and 443 for both hostnames
  network         private Compose network $INTERNAL_NETWORK
  volumes         ocx/codex/caddy volumes preserved across reruns; token bootstrapped once
  config          hub.managementPublicOrigin set to https://$DASHBOARD_DOMAIN, other settings kept
  checks          Ubuntu, packages, source, host address, both DNS names, resources, ports
  dry-run         install, build, and container start are skipped before any write
  no-op           make install and any Git write are never performed
EOF
}

# Parse flags, then run the read-only preflight and the deploy. main is only invoked when the
# script is executed, so tests can source the functions without side effects.
main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --target-ip)
        [ "$#" -ge 2 ] || die "--target-ip requires a value"
        TARGET_IP="$2"; shift ;;
      --domain)
        [ "$#" -ge 2 ] || die "--domain requires a value"
        DOMAIN="$2"; shift ;;
      --dashboard-domain)
        [ "$#" -ge 2 ] || die "--dashboard-domain requires a value"
        DASHBOARD_DOMAIN="$2"; shift ;;
      --dry-run) DRY_RUN=1 ;;
      --print-plan) PRINT_PLAN_ONLY=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage; die "unknown argument: $1" ;;
    esac
    shift
  done
  # Deprecated alias retained so an older copy script still supplies the same value.
  [ -n "$TARGET_IP" ] || TARGET_IP="${OCX_EXPECTED_PUBLIC_IP:-}"

  validate_config

  if [ "$PRINT_PLAN_ONLY" -eq 1 ]; then
    print_plan
    log "print-plan complete; no environment access performed"
    exit 0
  fi

  print_plan

  if [ "$DRY_RUN" -eq 1 ]; then
    run_preflight
    log "dry run: all read-only checks passed; no changes were made"
    exit 0
  fi

  run_preflight
  install_and_start_docker
  preflight_docker
  # Every exit path cleans transient files and restores an uncommitted Caddy edit.
  trap on_exit EXIT
  deploy_compose
  wait_for_health
  wait_for_https
  check_public_boundary
  check_authenticated_catalog
  print_next_steps
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
