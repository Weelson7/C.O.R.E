# C.O.R.E. Docs Quick Reference

This file is the fast index for the Docs folder.

## Folder Map

- Branding: visual identity and tone
	- [Docs/Branding/Philosophy.md](Branding/Philosophy.md)
	- [Docs/Branding/Style.md](Branding/Style.md)
- Services: one file per service
	- [Docs/Services/0_Netbird.md](Services/0_Netbird.md)
	- [Docs/Services/1_Indexer.md](Services/1_Indexer.md)
	- [Docs/Services/2_Adguard.md](Services/2_Adguard.md)
	- [Docs/Services/3_Jellyfin.md](Services/3_Jellyfin.md)
	- [Docs/Services/4_Suwayomi.md](Services/4_Suwayomi.md)
	- [Docs/Services/5_Kasm.md](Services/5_Kasm.md)
	- [Docs/Services/6_Crafty.md](Services/6_Crafty.md)
	- [Docs/Services/7_ttyd.md](Services/7_ttyd.md)
	- [Docs/Services/8_qBittorrent.md](Services/8_qBittorrent.md)
	- [Docs/Services/9_Jupyter.md](Services/9_Jupyter.md)
	- [Docs/Services/10_OnlyOffice.md](Services/10_OnlyOffice.md)
	- [Docs/Services/11_Doom.md](Services/11_Doom.md)
	- [Docs/Services/12_Seafile.md](Services/12_Seafile.md)
	- [Docs/Services/13_ncdu-web-viewer.md](Services/13_ncdu-web-viewer.md)
	- [Docs/Services/14_Music-assistant.md](Services/14_Music-assistant.md)
- Architecture
	- [Docs/Architecture.md](Architecture.md)

## Documentation Rules

1. Keep service files short, practical, and directly actionable.
2. Prefer exact commands and concrete values over generic explanations.
3. Keep naming and section order identical across all service files.
4. Mirror deploy.sh behavior exactly; do not describe flows that are not in the script.
5. Link related docs instead of duplicating long blocks.

## Required Service File Structure

Every service markdown file must use this exact order.

1. Table of content
2. Infos
3. Commands
4. Runtime parameters
5. Deployment sequence
6. Files (custom-made services only)

## Section Expectations

### 1. Table of content

- Link to every section in the file.
- Keep anchor names stable.

### 2. Infos

- Explain what the service is.
- Explain what it does inside C.O.R.E.
- State why it exists in the mesh.

### 3. Commands

- Include start, stop, restart, status, logs.
- Include edit/reload commands when applicable.
- Use real paths and service names.

### 4. Runtime parameters

- Runtime role policy (default alpha on node 0 and optional beta/gamma assignments when applicable).
- Network exposure (domain, host, port).
- Required config tweaks and environment variables.
- Security constraints (auth, bind IP, mesh-only rules).

### 5. Deployment sequence

- Reference the corresponding deploy.sh.
- Explain each deploy step in order.
- Include validation steps (nginx test, DNS check, service health check).
- Include rollback or recovery hint if deployment fails.

### 6. Files (custom-made services)

- List custom source files.
- Summarize each file's role in one or two lines.
- Include only meaningful behavior, no long code dumps.

## Service Template (Copy/Paste)

```md
# <Service Name>

## Table of content
- [Infos](#infos)
- [Commands](#commands)
- [Runtime parameters](#runtime-parameters)
- [Deployment sequence](#deployment-sequence)
- [Files](#files)

## Infos
- What it is:
- What it does:
- Why this service exists in C.O.R.E:

## Commands
- Start:
- Stop:
- Restart:
- Status:
- Logs:
- Edit/Reload:

## Runtime parameters
- Node(s):
- Domain:
- Port(s):
- Volumes/Data path:
- Environment/config tweaks:
- Security constraints:

## Deployment sequence
1. Step 1 from deploy.sh + explanation
2. Step 2 from deploy.sh + explanation
...
3. Validation checks
4. Failure handling notes

## Files
- <file path>: short role summary
- <file path>: short role summary
```

## Quick Quality Checklist

- Section order is correct.
- Commands are tested and current.
- Runtime values match actual deployment.
- deploy.sh explanation is exhaustive but concise.
- File summaries are streamlined and practical.

## Supervisor Note

- The orchestration control service is documented under the label `x_Supervisor`.
- Service-level alpha/beta/gamma assignment is dynamic and Supervisor-managed.
