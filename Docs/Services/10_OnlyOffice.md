# C.O.R.E OnlyOffice DocSpace

## Table of content
- [Infos](#infos)
- [Commands](#commands)
- [Runtime parameters](#runtime-parameters)
- [Deployment sequence](#deployment-sequence)
- [Files](#files)

## Infos
- What it is: A containerized OnlyOffice DocSpace instance for document editing and collaboration.
- What it does: Provides online document editing, spreadsheet, and presentation capabilities with real-time collaboration.
- Why this service exists in C.O.R.E: Enables private document editing and office suite functionality within the mesh network.

## Commands
- Start: `sudo docker compose -f /opt/core/onlyoffice/compose.yaml up -d`
- Stop: `sudo docker compose -f /opt/core/onlyoffice/compose.yaml down`
- Restart: `sudo docker compose -f /opt/core/onlyoffice/compose.yaml restart`
- Status: `sudo docker ps --filter name=core-onlyoffice`
- Logs: `sudo docker logs -f core-onlyoffice`
- Edit/Reload: edit `src/10_OnlyOffice/deploy.sh`, rerun deploy script

## Runtime parameters
- Node(s): alpha on node-0
- Domain: onlyoffice.core
- Port(s): External ingress 443 and 80 (redirect), internal loopback publish 127.0.0.1:8000 by default
- Volumes/Data path:
	- Deploy script: `src/10_OnlyOffice/deploy.sh`
	- Runtime root: `/opt/core/onlyoffice`
	- Data path: `/opt/core/onlyoffice/data`
	- Compose file (generated): `/opt/core/onlyoffice/compose.yaml`
- Environment/config tweaks:
	- Image: `onlyoffice/docspace:latest`
- Security constraints:
	- TLS mandatory for ingress
	- HTTP Basic Auth enforced at ingress

## Deployment sequence
1. Validate host and install dependencies
2. Provision runtime directories
3. Generate container runtime definition
4. Start OnlyOffice container
5. Provision TLS certificate
6. Configure Nginx ingress
7. Validate DNS and ingress health

## Files
- `src/10_OnlyOffice/deploy.sh`: Deployment script for OnlyOffice DocSpace
- `src/10_OnlyOffice/wipe.sh`: Cleanup script for OnlyOffice runtime
