#!/bin/sh
# Build time, as root: installs the start script, the banner and the tools they need.
set -e
dir=/usr/local/share/agent-sandbox

need=""
command -v ip >/dev/null 2>&1 || need="$need iproute2"
command -v update-ca-certificates >/dev/null 2>&1 || need="$need ca-certificates"
if [ -n "$need" ]; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $need
    rm -rf /var/lib/apt/lists/*
  elif command -v apk >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    apk add --no-cache $need
  else
    echo "agent-sandbox: install$need yourself (no apt-get or apk)" >&2
    exit 1
  fi
fi

mkdir -p "$dir"
for f in entrypoint.sh banner.sh; do
  # Strip Windows line endings in case git checked the file out with CRLF
  sed 's/\r$//' "./$f" > "$dir/$f"
  chmod 755 "$dir/$f"
done

# docker-in-docker's entrypoint blocks until the inner dockerd is up, and it runs before ours (this
# feature installs after it, so that our proxy variables can't reach other features' installs).
# Wrap it so that our setup comes first. Its path is how the dev container CLI calls it.
init=/usr/local/share/docker-init.sh
if [ -f "$init" ] && ! grep -q agent-sandbox "$init"; then
  mv "$init" /usr/local/share/docker-init.orig.sh
  cat > "$init" <<'EOF'
#!/bin/sh
# Wrapper installed by the agent-sandbox feature: its setup (gVisor guard, CA, agent-proxy, NAT)
# first, then docker-in-docker's own entrypoint.
/usr/local/share/agent-sandbox/entrypoint.sh --before-dind
exec /usr/local/share/docker-init.orig.sh "$@"
EOF
  chmod 755 "$init"
fi

# The banner, once per container start, in the first interactive shell. VS Code's terminals are
# interactive shells that aren't login shells, so profile.d alone isn't enough.
hook='[ -x /usr/local/share/agent-sandbox/banner.sh ] && /usr/local/share/agent-sandbox/banner.sh'
for rc in /etc/bash.bashrc /etc/zsh/zshrc /etc/profile.d/agent-sandbox.sh; do
  case $rc in
    /etc/profile.d/*) [ -d /etc/profile.d ] || continue ;;
    *) [ -f "$rc" ] || continue ;;
  esac
  grep -qF "$hook" "$rc" 2>/dev/null || printf '\n# agent-sandbox: banner after each container start\n%s\n' "$hook" >> "$rc"
done
