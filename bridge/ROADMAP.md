# REALLBLACK Bridge Roadmap

## Current stable/local baseline
- Installed on PC before this batch: 4.2.2
- Repository candidate: 4.2.5 (awaiting GitHub Actions completion)
- Core mode: safe read-only
- Transport: GitHub issue comments
- Auto-start: Startup launcher + Scheduled Task
- Defender: enabled

## Completed
- PING / BRIDGE_INFO / CAPABILITIES / SYSINFO
- PROC_LIST / WINDOWS_LIST / SERVICE_LIST
- FILE_INFO / LIST / READ_TEXT
- SCREEN_INFO
- SHA-256 validation
- PowerShell syntax validation
- Atomic replacement
- Health-check
- Last-good backup
- Watchdog/rollback protections
- GitHub Actions manifest publication
- 4.2.3 reusable heartbeat design (single comment updated every 60s)
- 4.2.4 BRIDGE_DIAG
- 4.2.5 RESOURCE_SNAPSHOT + APP_STATUS
- Isolated screen helper 1.0.0
- Verified screen-helper installer + separate manifest

## In progress
- Validate 4.2.5 in GitHub Actions
- Local install/test of latest validated core
- Local install/test of screen helper

## Prepared but NOT remotely wired
- Isolated file helper source and installer
- Intended bounded operations: INFO, LIST, MKDIR, COPY, MOVE, RENAME, WRITE_TEXT
- Delete behavior is recycle-bin only
- Remote wiring of write-capable file operations was blocked and must not be bypassed

## Planned safe evolution
- Screen capture remains isolated from the core agent
- File transfer should use a separate bounded channel
- Controlled app/window actions should be allowlisted
- Terminal must remain bounded/controlled rather than unrestricted
- GitHub should eventually become fallback/bootstrap rather than high-frequency transport
- Persistent transport can be evaluated later with device identity, scopes and audit
- MCP-style structured tools are the final integration target

## Non-negotiable safeguards
- Do not disable Defender to make the bridge work
- Do not build credential/token extraction
- Do not expose an unrestricted admin shell
- Do not add covert persistence
- Do not allow arbitrary path escape outside approved roots
- No reboot without explicit user authorization
