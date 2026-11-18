# agent-sandbox feature

A dev container feature that turns a dev container into a sandbox for coding agents. It is one
half of agent-sandbox; the other half (the start step and the images it runs: launcher, prepare,
egress filter, credential proxy) lives in a separate repository, and the full documentation is
there.

What this feature does inside the dev container:

- refuses to start unless the container runs under [gVisor](https://gvisor.dev);
- sends all traffic through the sandbox's own credential proxy (`http://agent-proxy:3128`) and
  trusts that proxy's CA;
- mounts the sandbox's workspace volume at `/workspaces` (the repo is copied in once, at the first
  open; there is no mount of the host's folder);
- sets up outbound NAT and a `daemon.json` for Docker-in-Docker under gVisor;
- shows a banner in the first terminal after each start: gVisor, the active rules, secrets files
  found, hosts that get credentials, and messages from the start step.

It only works together with the start step in `initializeCommand`, which creates the volumes,
networks and proxies this feature expects. Reference:

```jsonc
"features": {
  "ghcr.io/rheuvel89/agent-sandbox-feature/agent-sandbox:0": { "project": "my-project" }
}
```

Releases: tag `vX.Y.Z` (equal to `version` in `src/agent-sandbox/devcontainer-feature.json`);
the workflow publishes the feature to `ghcr.io`. The images repo is tagged with the same version.
