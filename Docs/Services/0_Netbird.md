# C.O.R.E Netbird


## Table of content
- [Infos](#infos)
- [Commands](#commands)
- [Runtime parameters](#runtime-parameters)
- [Deployment sequence](#deployment-sequence)
- [Files](#files)


## Infos
- What it is: The mesh-control service bootstrap used to enroll a host into the C.O.R.E Netbird network.
- What it does: Installs Netbird (apt first, snap fallback), registers the node using a runtime-provided setup key, and verifies connected mesh state.
- Why this service exists in C.O.R.E: It is the network trust anchor for `.core` service discovery and secure east-west connectivity.


## Commands
- Start: `sudo netbird up` (or `sudo /snap/bin/netbird up` when snap-installed)
- Stop: `sudo netbird down` (or `sudo /snap/bin/netbird down` when snap-installed)
- Restart: `sudo netbird down && sudo netbird up`
- Status: `sudo netbird status` (or `sudo /snap/bin/netbird status` when snap-installed)
- Logs: `sudo journalctl -u netbird -f`
- Reload: `bash src/0_Netbird/deploy.sh`


## Runtime parameters
- Node(s): Mandatory baseline service for each participating C.O.R.E node discovered in Netbird.
- Domain: Mesh fabric service (no direct ingress virtual host required).
- Port(s): Controlled by Netbird/WireGuard runtime; no app listener port exposed by this service.
- Volumes/Data path:
    - Script source: `src/0_Netbird/deploy.sh`
    - Wipe script: `src/0_Netbird/wipe.sh`
    - Runtime status artifact: `/tmp/core-netbird-status.txt`
- Environment/config tweaks:
    - `NETBIRD_SETUP_KEY` (required): setup key used to enroll/register the node. If not set, script prompts at runtime using hidden input.
    - `NETBIRD_MGMT_URL` (optional): overrides Netbird management URL via `--management-url`.
    - `NETBIRD_ADMIN_URL` (optional): overrides admin URL via `--admin-url`.
    - `NETBIRD_IFACE_BLACKLIST` (optional): interface blacklist passed through `--interface-blacklist`.
    - `PURGE_PACKAGES` (optional, wipe only): controls whether apt/snap packages are purged during wipe. Defaults to `true`.
    - `FORCE` (optional, wipe only): skips the `WIPE` confirmation prompt when set to `true`. Defaults to `false`.
- Security constraints:
    - Both scripts are Ubuntu-only and exit when the host OS is not Ubuntu.
    - Setup key is sensitive and should be short-lived/rotated according to Netbird policy.
    - Runtime prompt for setup key uses hidden terminal input.
    - Scripts require `sudo` and modify system package state and Netbird runtime connectivity.


## Deployment sequence
1. Prompt for `NETBIRD_SETUP_KEY` if not pre-exported in environment (hidden input).
2. Validate host OS is Ubuntu; exit if not.
3. Verify required commands are present: `sudo`, `apt`.
4. Run `apt update` and install `ca-certificates` as baseline dependency.
5. Install Netbird via `apt`; if the apt package is unavailable, fall back to `snap`. If `snapd` is not present, install it first and activate the snap socket before installing Netbird.
6. Resolve the Netbird binary path (`netbird` in PATH or `/snap/bin/netbird`); fail if neither is found.
7. Check if the node is already connected via `netbird status`; log re-registration notice if so, proceed regardless.
8. Build `netbird up` argument list from environment variables (`NETBIRD_SETUP_KEY`, `NETBIRD_MGMT_URL`, `NETBIRD_ADMIN_URL`, `NETBIRD_IFACE_BLACKLIST`).
9. Stop any running Netbird systemd services and run `netbird down` to clean existing runtime state before re-enrolling.
10. Execute `netbird up` with the built argument list to register the node.
11. Run `netbird status`, persist output to `/tmp/core-netbird-status.txt`, and fail deployment if connected state is not detected.


Validation checks:
- `sudo netbird status` (or `sudo /snap/bin/netbird status`)
- `sudo netbird status --detail` (or `sudo /snap/bin/netbird status --detail`)
- `grep -iE 'connected|management:[[:space:]]*connected' /tmp/core-netbird-status.txt`


Failure handling notes:
- `apt` package missing: script automatically falls back to snap install.
- `snap` unavailable: script installs `snapd` and activates the socket automatically before retrying.
- Enrollment rejected: generate a new setup key in the Netbird management UI and rerun deploy.
- Connected state missing after `up`: inspect `sudo netbird status --detail` (or snap path equivalent) and service logs (`sudo journalctl -u netbird -f`).
- Existing stale registration: script runs `netbird down` before `up` automatically; remove stale peer from Netbird management UI if enrollment is still rejected.


## Files
- `src/0_Netbird/deploy.sh`: Idempotent host bootstrap and node-enrollment script. Handles apt-first/snap-fallback install, argument assembly, runtime cleanup, and post-enrollment connection verification.
- `src/0_Netbird/wipe.sh`: Cleanup script. Stops and disables Netbird services, runs `netbird down`, removes apt/snap packages (controlled by `PURGE_PACKAGES`), and deletes all Netbird runtime artifacts and configuration directories.