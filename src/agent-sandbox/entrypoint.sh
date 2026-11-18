#!/bin/sh
# Runs as root at every container start (a feature entrypoint, before the user's processes; no
# sudo needed, which wouldn't work under gVisor anyway). The dev container CLI calls it as one line
# of PID 1's script without "set -e", so only a signal to PID 1 stops the container.
#
# The setup must be done before VS Code connects, which it does as soon as the container has
# started. docker-in-docker's entrypoint runs before this one and blocks until the inner dockerd is
# up (11 s or more), so install.sh wraps it: the wrapper calls this script with --before-dind first,
# and the normal call later finds the setup done. (Installing this feature first instead would put
# its proxy variables into the image build of every feature installed after it.)
#
# 1. Refuse to run outside gVisor.
# 2. Wait for the sandbox's CA certificate and the credential proxy's address (the start step's
#    creds service writes both into the volume at /var/lib/agent-sandbox).
# 3. Trust the CA; make the name agent-proxy point at the credential proxy (no DNS in the sandbox).
# 4. With Docker-in-Docker: the inner dockerd's daemon.json (before it starts) and outbound NAT,
#    since it runs without iptables.
# 5. Prepare the banner for the first terminal.
# Messages go to the container log (docker logs <container>) and into the banner.
done_marker=/run/agent-sandbox-setup-done
if [ "$1" != "--before-dind" ] && [ -e "$done_marker" ]; then
  # Done by the wrapper around docker-in-docker's entrypoint, earlier in this start. (The CLI calls
  # entrypoints without arguments, and a bare "exec" would carry on with the script.)
  rm -f "$done_marker"
  if [ $# -gt 0 ]; then exec "$@"; fi
  exit 0
fi

public=/var/lib/agent-sandbox
ca=$public/agent-sandbox-ca.crt
address_file=$public/proxy-address
pending=/run/agent-sandbox-banner/pending
notes=""

log() { echo "agent-sandbox: $*"; }
note() { log "$*"; notes="$notes$*
"; }

# Stops the container: an exit code alone doesn't (see above)
refuse() {
  echo "agent-sandbox: REFUSING TO START: $1" >&2
  echo "agent-sandbox: $2" >&2
  kill -TERM 1
  sleep 5
  exit 1
}

# --- 1. gVisor guard, read-only CA volume ----------------------------------------------------
# Both gVisor signals are true under runsc and runsc-dind and false under runc, privileged or not.
if ! { dmesg 2>/dev/null | head -n 1 | grep -q 'Starting gVisor' && uname -r | grep -q -- '-gvisor$'; }; then
  refuse "this dev container is not running under gVisor." \
    "add \"--runtime=runsc-dind\" (or \"--runtime=runsc\") to runArgs in devcontainer.json."
fi
# The volume is shared with the filter and the credential proxy, so the sandbox must not be able to
# write it, not even as root (which Docker-in-Docker gives it). Only a read-only mount made by Docker
# guarantees that; a feature can't declare one, so the repo's devcontainer.json does.
options=$(awk -v dir="$public" '$2 == dir { o = $4 } END { print o }' /proc/mounts)
case ",$options," in
  *,ro,*) ;;
  *) refuse "$public is not mounted read-only (mount options: ${options:-not mounted})." \
       "add to \"mounts\" in devcontainer.json: \"source=agent-sandbox-ca-\${devcontainerId},target=$public,type=volume,readonly\"" ;;
esac

# --- 2. Wait for the start step's files ------------------------------------------------------
i=0
while { [ ! -s "$ca" ] || [ ! -s "$address_file" ]; } && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done

# --- 3. CA and agent-proxy -----------------------------------------------------------------
bundle=/etc/ssl/certs/ca-certificates.crt
if [ -s "$ca" ]; then
  mkdir -p /usr/local/share/ca-certificates
  cp "$ca" /usr/local/share/ca-certificates/agent-sandbox-ca.crt
  if [ -f "$bundle" ]; then
    # update-ca-certificates takes ~5 s under gVisor (it rehashes every certificate), and VS Code
    # connects before that. So the CA goes straight into the bundle (replacing an earlier sandbox
    # CA), and the full run, for tools that read the hashed folder, happens in the background.
    awk '/^# agent-sandbox CA begin$/ { skip = 1 } !skip { print } /^# agent-sandbox CA end$/ { skip = 0 }' \
      "$bundle" > /tmp/agent-sandbox-bundle
    { echo "# agent-sandbox CA begin"; cat "$ca"; echo "# agent-sandbox CA end"; } >> /tmp/agent-sandbox-bundle
    cat /tmp/agent-sandbox-bundle > "$bundle"
    rm -f /tmp/agent-sandbox-bundle
    log "trusting the sandbox's CA"
    (update-ca-certificates >/dev/null 2>&1 &)
  elif update-ca-certificates >/dev/null 2>&1; then
    log "trusting the sandbox's CA"
  else
    note "WARNING: update-ca-certificates failed; HTTPS through the proxy will fail certificate checks."
  fi
else
  note "WARNING: no CA certificate in $public after 30 s; HTTPS through the proxy will fail certificate checks."
fi

address=$(cat "$address_file" 2>/dev/null)
if [ -n "$address" ]; then
  # /etc/hosts is a file Docker mounts: rewrite it in place, never replace it
  grep -v '[[:space:]]agent-proxy$' /etc/hosts > /tmp/agent-sandbox-hosts
  echo "$address agent-proxy" >> /tmp/agent-sandbox-hosts
  cat /tmp/agent-sandbox-hosts > /etc/hosts
  rm -f /tmp/agent-sandbox-hosts
  log "agent-proxy is $address"
else
  note "WARNING: the credential proxy's address is missing; nothing can reach the internet. Is the creds container running?"
fi

# --- 4. Outbound NAT for Docker-in-Docker ------------------------------------------------------
# From gVisor's images/basic/docker/start-dockerd.sh. Safe to repeat.
setup_nat() {
  dev=$(ip route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}')
  # The sandbox network is internal (no default route): take the first real interface instead
  [ -n "$dev" ] || dev=$(ip -4 -o addr show scope global | awk '$2 !~ /^(docker|br-|veth)/ {print $2; exit}')
  [ -n "$dev" ] || { note "WARNING: no network interface found; Docker-in-Docker has no network."; return; }
  own=$(ip -4 -o addr show dev "$dev" | awk '{print $4}' | cut -d/ -f1)
  ipt=iptables
  command -v iptables-legacy >/dev/null 2>&1 && ipt=iptables-legacy
  echo 1 > /proc/sys/net/ipv4/ip_forward || note "WARNING: could not enable IP forwarding for Docker-in-Docker."
  for proto in tcp udp; do
    $ipt -t nat -C POSTROUTING -o "$dev" -p "$proto" -j SNAT --to-source "$own" 2>/dev/null \
      || $ipt -t nat -A POSTROUTING -o "$dev" -p "$proto" -j SNAT --to-source "$own" \
      || { note "WARNING: could not add the $proto NAT rule; Docker-in-Docker has no network."; return; }
  done
  log "Docker-in-Docker NAT ready on $dev ($own)"
}
if command -v dockerd >/dev/null 2>&1; then
  # Under gVisor: no iptables (NAT below), no overlayfs, and pulls through the sandbox's proxy.
  # Written at every start, so another feature's install can't have replaced it.
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'EOF'
{
  "iptables": false,
  "ip6tables": false,
  "mtu": 1500,
  "storage-driver": "vfs",
  "features": { "containerd-snapshotter": false },
  "proxies": {
    "http-proxy": "http://agent-proxy:3128",
    "https-proxy": "http://agent-proxy:3128",
    "no-proxy": "localhost,127.0.0.1,::1"
  }
}
EOF
  if command -v iptables >/dev/null 2>&1; then setup_nat; fi
fi

# --- 5. Banner -----------------------------------------------------------------------------
# A new file at every start; the first interactive shell shows it and removes it. The folder is
# writable for everyone (not sticky), so the user's shell can remove root's file.
mkdir -p /run/agent-sandbox-banner
chmod 777 /run/agent-sandbox-banner
{
  echo "gVisor: yes ($(uname -r))"
  printf '%s' "$notes"
} > "$pending.tmp"
chmod 644 "$pending.tmp"
mv "$pending.tmp" "$pending"

if [ "$1" = "--before-dind" ]; then
  touch "$done_marker"
  exit 0
fi
exec "$@"
