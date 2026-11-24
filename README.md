# agent-sandbox feature

A dev container feature that turns a dev container into a sandbox for coding agents. It is one
half of agent-sandbox. The other half, the start step and the images it runs (launcher, prepare,
egress filter, credential proxy), lives in a separate repository, which also has the full
documentation: rules, credentials, secrets, commands and troubleshooting.

What this feature does inside the dev container:

- refuses to start unless the container runs under [gVisor](https://gvisor.dev);
- sends all traffic through the sandbox's own credential proxy (`http://agent-proxy:3128`) and
  trusts that proxy's CA;
- mounts the sandbox's workspace volume at `/workspaces`. The repo is copied in once, at the first
  open; there is no mount of the host's folder;
- for Docker-in-Docker under gVisor: writes the inner dockerd's `daemon.json`, sets up outbound NAT,
  and makes sure this setup is done before the docker-in-docker feature's slow start;
- sets your git identity for commits, from `~/.agent-sandbox/gitconfig` (see below);
- shows a banner in the first terminal after each start: gVisor, the version, the active rules,
  your files found, the hosts that get credentials, the git identity, and messages from the start
  step.

## Using it

The feature only works together with the start step in `initializeCommand`, which creates the
volumes, networks and proxies it expects. All of these go into `.devcontainer/devcontainer.json`:

```jsonc
"features": {
  "ghcr.io/rheuvel89/agent-sandbox-feature/agent-sandbox:0": { "project": "my-project" }
  // ... the repo's own features
},
"initializeCommand": "docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v ./.devcontainer:/project:ro <launcher-image>:0 render ${devcontainerId} ${localWorkspaceFolderBasename} | docker compose --project-directory .devcontainer -f - up -d",
"workspaceMount": "",
"workspaceFolder": "/workspaces/${localWorkspaceFolderBasename}",
"runArgs": [
  "--runtime=runsc-dind",
  "--network=agent-sandbox-${localWorkspaceFolderBasename}-${devcontainerId}",
  "--label=agent-sandbox.id=${devcontainerId}"
],
"mounts": [
  "source=agent-sandbox-ca-${devcontainerId},target=/var/lib/agent-sandbox,type=volume,readonly"
]
```

- `<launcher-image>` is the launcher image from the images repository. Its version must equal this
  feature's version (`:0` above): the start step uses the feature's version for every image.
- `initializeCommand` must not contain double quotes (Windows passes them on literally).
- `--runtime=runsc` instead of `runsc-dind` for a repo without Docker-in-Docker.
- The `mounts` line gives the sandbox its CA volume **read-only**, in a way even root inside the
  sandbox can't undo. The feature can't declare that itself: the feature schema only allows the
  object form, which drops `readonly`. Keep the string form. The feature refuses to start when the
  volume isn't mounted read-only.
- The start step refuses to open the sandbox, and says why, when one of these settings is missing.
- Open the root of a git clone. The base image needs `apt` or `apk`, and a user with uid 1000
  (like the `mcr.microsoft.com/devcontainers/*` images).

Option:

| Option | Default | Meaning |
|---|---|---|
| `project` | the folder name | Chooses the project folder in your home folder, `~/.agent-sandbox/<project>/`, with your secrets, credential rules and rule files for that project. Read by the start step. Letters, digits, `_`, `.` and `-` only. |

## Rules, credentials and secrets: where they go

A sandbox can reach only the hosts its rules allow, and its credential proxy adds credentials to
requests on the way out, so the agent never sees them. Both come in layers, lowest first:

| Layer | Where | For |
|---|---|---|
| built-in | built into the images | what every dev container needs (VS Code) |
| repo | `.devcontainer/agent-sandbox/` in the repo | what this project needs, shared with everyone through git |
| all your sandboxes | `~/.agent-sandbox/` | what you need everywhere: your model API, your git host |
| your project | `~/.agent-sandbox/<project>/` | your extras for one project |
| one sandbox | `~/.agent-sandbox/<project>/sandboxes/<folder>-<shortid>/` | one clone, e.g. its own bot token |

`<project>` is the `project` option; `<folder>-<shortid>` is the sandbox's name, shown in the banner
together with the exact paths it looks for. Secrets live only in your home folder: never in a repo
and never inside the sandbox.

In the repo (optional, only what the project needs):

```
.devcontainer/agent-sandbox/
  rules/allowed-domains.txt    hosts to allow
  rules/blocked-domains.txt    hosts to block even if an allow matches
  rules/allowed-ips.txt        addresses to allow (rarely needed)
  rules/blocked-ips.txt        addresses to block
  credentials.toml             credential rules
  upstream-ca/                 *.crt or *.pem: CAs of internal sites the proxy must trust
```

In your home folder, each of the three levels is a folder with the same files, all optional:

```
~/.agent-sandbox/                                          all your sandboxes
~/.agent-sandbox/<project>/                                your sandboxes of that project
~/.agent-sandbox/<project>/sandboxes/<folder>-<shortid>/   one sandbox

each with:
  secrets.env        NAME=value lines; credential rules use them as ${NAME}
  credentials.toml   credential rules
  rules/*.txt        the same four rule files as in the repo
  gitconfig          your git identity: [user] name and email
```

How the layers combine:

| Kind | Behaviour across layers |
|---|---|
| Rules | **Add up**: a host is allowed when any layer allows it, and **blocks always win** over allows. No layer can remove another layer's rule. |
| Credential rules | A layer's rule for a host **replaces** the rules of the layers before it for that host. So your own key for a host wins over the repo's, and a sandbox's over your project's. |
| Secrets (`secrets.env`) | Per name, the **most specific** level wins: one sandbox, then the project, then all sandboxes. |
| Git identity (`gitconfig`) | Per key (`name`, `email`), the most specific level wins. Only these two are read; nothing else in the file is used. Nothing set means nothing set. |

When changes apply: rules, credential rules and secrets within seconds, while the sandbox runs (also
when a file appears or disappears); the git identity at the next start. Repo files are always read
from the copy on your machine, not from the sandbox's copy, so the agent can't change its own rules;
edit them on your machine. The filter only ever sees the `rules` folders, never your secrets.

What is in effect: the banner, and on your machine:

```
docker exec <sandbox>-filter rules       the rules, and the layer each one comes from
docker exec <sandbox>-filter blocked     the most recent refused requests
```

### File formats

`allowed-domains.txt` (the other rule files take one entry per line):

```
api.example.com                     # exactly this host
.example.com                        # this domain and all its subdomains
login.example.com          strict   # every request must name exactly this host (shared hosting)
grafana.internal.example   private  # may resolve to a private address (VPN, LAN)
model.internal.example:8000 private # port 8000 only (listed ports replace 80 and 443)
```

A line with an error is skipped and reported (banner, `rules`); the other lines still apply.

`credentials.toml`. Every host in it must also be allowed by a rule. Credentials are only added
over https:

```toml
# A fixed header (API key, token); give the tool inside the sandbox any placeholder value
[[header]]
hosts = ["api.anthropic.com"]
name  = "x-api-key"
value = "${ANTHROPIC_API_KEY}"

# OAuth: the proxy fetches and refreshes the token itself; the agent's own token request gets a
# placeholder, so a real token never enters the sandbox
[[oauth]]
hosts     = ["graph.microsoft.com"]
token_url = "https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token"
[oauth.params]
grant_type    = "client_credentials"
client_id     = "${GRAPH_CLIENT_ID}"
client_secret = "${GRAPH_CLIENT_SECRET}"
```

A rule whose `${NAME}` is in none of the secrets files is skipped, and the banner says which.

`secrets.env`:

```
ANTHROPIC_API_KEY=sk-ant-...
GRAPH_CLIENT_SECRET="..."
```

`gitconfig`:

```
[user]
    name = Your Name
    email = you@example.com
```

Your own `~/.gitconfig` is never copied into a sandbox; without this file, git in the sandbox has no
name and email and refuses to commit (the banner says no identity is set).

Keep `.devcontainer/` under review like CI configuration (e.g. CODEOWNERS): a repo's
`credentials.toml` decides where your secrets may be sent, and its `project` option chooses which
of your project folders applies.

## Releases

Tag `vX.Y.Z`, equal to `version` in `src/agent-sandbox/devcontainer-feature.json`. The workflow
then publishes the feature to `ghcr.io/rheuvel89/agent-sandbox-feature/agent-sandbox` with the tags
`X.Y.Z`, `X.Y`, `X` and `latest`. The images repository is tagged with the same version.

The feature is tested end to end from the images repository (`tests/feature/test-feature.ps1`),
because the test needs the images built there.
