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
- Restart: `sudo netbird down ; sudo netbird up`
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
- Security constraints:
	- Script is Ubuntu-only and exits when host OS is not Ubuntu.
	- Setup key is sensitive and should be short-lived/rotated according to Netbird policy.
	- Runtime prompt for setup key uses hidden terminal input.
	- Script requires `sudo` and modifies system package state and Netbird runtime connectivity.

## Deployment sequence
1. Prompt for `NETBIRD_SETUP_KEY` if not pre-exported in environment.
2. Validate host/runtime prerequisites: Ubuntu OS check plus required commands (`sudo`, `apt`).
3. Install base dependency (`ca-certificates`).
4. Install Netbird agent using `apt` first; if `apt` package resolution fails, install via `snap` fallback.
5. Resolve the executable path (`netbird` in PATH or `/snap/bin/netbird`) and fail if missing.
6. If node is already connected, proceed with re-registration notice.
7. Build `netbird up` arguments from runtime/environment settings and enforce clean reconnect flow (`down` then `up --setup-key ...`).
8. Validate post-enrollment state using `status`, persist output to `/tmp/core-netbird-status.txt`, and fail deployment if connected state is not detected.

Validation checks:
- `sudo netbird status` (or `sudo /snap/bin/netbird status`)
- `sudo netbird status --detail` (or `sudo /snap/bin/netbird status --detail`)
- `grep -iE 'connected|management:[[:space:]]*connected' /tmp/core-netbird-status.txt`

Failure handling notes:
- `apt` package missing: script automatically falls back to snap install.
- `snap` unavailable: ensure `snapd` can be installed/enabled, then rerun script.
- Enrollment rejected: generate a new setup key in Netbird management UI and rerun deploy.
- Connected state missing after `up`: inspect `sudo netbird status --detail` (or snap path equivalent) and service logs (`sudo journalctl -u netbird -f`).
- Existing stale registration: keep script behavior (`netbird down` before `up`) or remove stale peer entry from Netbird management if needed.

## Files
- `src/0_Netbird/deploy.sh`: Idempotent host bootstrap and node-enrollment script for Netbird with apt-first/snap-fallback install logic.
- `src/0_Netbird/wipe.sh`: Cleanup script for Netbird runtime artifacts and both apt/snap package removal paths.
