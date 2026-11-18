#!/bin/sh
# Shows the sandbox's banner once per container start, in the first interactive shell (hooked
# into the shells' rc files by install.sh). Parts:
#   from the entrypoint          the gVisor line and its warnings
#   banner.txt  (creds)          version, project, sandbox, commands, secrets files, credential hosts
#   rules-status.txt (filter)    whether the rules were applied, or why not
#   seed.txt    (seed)           what the first open copied in (only after the first open)
pending=/run/agent-sandbox-banner/pending
public=/var/lib/agent-sandbox

# Only in a terminal: VS Code and the dev container CLI start interactive shells without one to read
# the environment, and those must not use up the banner.
[ -t 1 ] || exit 0
# Only the shell that manages to take the file shows it
mine=$pending.$$
mv "$pending" "$mine" 2>/dev/null || exit 0

line() { printf '%s\n' "------------------------------------------------------------------------"; }
line
echo "agent-sandbox"
sed 's/^/  /' "$mine"
rm -f "$mine"
if [ -s "$public/banner.txt" ]; then
  sed 's/^/  /' "$public/banner.txt"
else
  echo "  (the credential proxy's banner is missing)"
fi
if [ -s "$public/rules-status.txt" ]; then
  # The filter's status, first line only unless the rules weren't applied
  if grep -q 'NOT applied\|skipped' "$public/rules-status.txt"; then
    sed 's/^/  rules: /' "$public/rules-status.txt"
  else
    head -n 1 "$public/rules-status.txt" | sed 's/^/  rules: /'
  fi
fi
if [ -s "$public/seed.txt" ]; then
  sed 's/^/  /' "$public/seed.txt"
fi
line
exit 0
