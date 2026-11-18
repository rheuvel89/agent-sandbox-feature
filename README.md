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
- shows a banner in the first terminal after each start: gVisor, the active rules, the secrets
  files found, the hosts that get credentials, and messages from the start step.

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
]
```

- `<launcher-image>` is the launcher image from the images repository. Its version must equal this
  feature's version (`:0` above): the start step uses the feature's version for every image.
- `initializeCommand` must not contain double quotes (Windows passes them on literally).
- `--runtime=runsc` instead of `runsc-dind` for a repo without Docker-in-Docker.
- The start step refuses to open the sandbox, and says why, when one of these settings is missing.
- Open the root of a git clone. The base image needs `apt` or `apk`, and a user with uid 1000
  (like the `mcr.microsoft.com/devcontainers/*` images).

Option:

| Option | Default | Meaning |
|---|---|---|
| `project` | the folder name | Chooses the project secrets file `~/.agent-sandbox/<project>/secrets.env`. Read by the start step. |

## Releases

Tag `vX.Y.Z`, equal to `version` in `src/agent-sandbox/devcontainer-feature.json`. The workflow
then publishes the feature to `ghcr.io/rheuvel89/agent-sandbox-feature/agent-sandbox` with the tags
`X.Y.Z`, `X.Y`, `X` and `latest`. The images repository is tagged with the same version.

The feature is tested end to end from the images repository (`tests/feature/test-feature.ps1`),
because the test needs the images built there.
