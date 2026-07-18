# WgSense Architecture Audit - 2026-07-16

## Verdict

The project is functional but not yet structurally clean. The current risk is
not a single broken function; it is accumulation:

- UI client state, API transport, profile file IO, transfer logic, proxy logic,
  and privileged daemon launch are concentrated in `DaemonClient.swift`.
- Main dashboard layout, tile models, tile controls, transfer views, editing
  behavior, animation helpers, and shared visual primitives are concentrated in
  `MainView.swift`.
- Proxy UI and Mihomo API surface are useful, but still too coupled to one large
  screen and one large Swift client.
- Backend packages are more coherent than the macOS UI, but `api.Server` and
  `proxy.Service` are also aggregation points that should be split before they
  become hard to test.
- Privileged service installation is still transitional. App-owned daemon mode is
  safer for now; persistent system service should be promoted only through a
  generated helper/install path, not static plist files.

## Immediate Fixes Applied

- Removed the macOS client's personal development fallback path
  `/Users/adams/Projects/wgsense/core/wgsense-daemon`; fallback is now
  `/usr/local/libexec/wgsense-daemon`.
- Replaced hard-coded packaging plists with templates:
  - `packaging/com.wgsense.daemon.plist.template`
  - `packaging/com.wgsense.receive-mover.plist.template`
- Added `packaging/wgsense-install-services.sh`, which generates real plists for
  the target user and installs binaries/scripts intentionally.
- Added root and self-copy guards to the installer.

## Current Hotspots

| File | Lines | Problem |
| --- | ---: | --- |
| `platforms/macos/WgSense/Views/MainView.swift` | 3154 | Too many responsibilities: tile layout, tile content, controls, transfer UI, animations, editing, status cards. |
| `platforms/macos/WgSense/DaemonClient.swift` | 1638 | Transport, models, daemon auth, profile disk IO, transfer API, proxy API, config sync all in one observable object. |
| `platforms/macos/WgSense/Views/ProxyView.swift` | 1761 | Large feature screen; should be split by concerns: overview, proxy groups, connections, rules, settings/logs. |
| `core/internal/proxy/service.go` | 1025 | Service lifecycle and HTTP handlers live together; handlers should move behind a router/handler file. |
| `core/api/api.go` | 495 | Top-level API mux mixes core daemon, profile, transfer, and shutdown handlers. Manageable now, but should be split. |

## Refactor Direction

### 1. Split macOS state clients first

Keep one app-level `DaemonClient` facade if needed, but move implementation to:

- `DaemonAPIClient`: low-level HTTP request/response, error decoding, timeout
  policy.
- `DaemonLifecycleController`: reachability, app-owned daemon launch/shutdown,
  authorization state.
- `ProfileStore`: local profile disk IO and profile API sync.
- `TransferClient`: LocalSend discovery, receive approvals, sends, progress.
- `ProxyClient`: Mihomo status, proxies, rules, connections, settings.
- `AppSettingsStore`: trusted network prefixes, automation policy, UI defaults.

Rule: Swift views should not construct endpoint strings or parse daemon error
bodies directly.

### 2. Split large Swift views by feature boundary

Proposed files:

- `Dashboard/TileGridView.swift`
- `Dashboard/TileModels.swift`
- `Dashboard/TileControls.swift`
- `Dashboard/ReceiveTileView.swift`
- `Dashboard/SendTileView.swift`
- `Dashboard/LogsTileView.swift`
- `Proxy/ProxyOverviewView.swift`
- `Proxy/ProxyGroupsView.swift`
- `Proxy/ProxyConnectionsView.swift`
- `Proxy/ProxyRulesView.swift`
- `Proxy/ProxySettingsView.swift`

Rule: files above 800 lines need justification; above 1200 lines should be split.

### 3. Keep backend package boundaries strict

Backend package intent should be:

- `policy`: automation decisions only.
- `tunnel`: WireGuard interface, routes, endpoint resolution, cleanup.
- `transfer`: LocalSend protocol, discovery, receive/send tasks.
- `proxy`: Mihomo API and persistent proxy settings.
- `api`: HTTP routing and serialization only.

Rule: daemon API handlers should not implement domain behavior; they should call
package services.

### 4. Privileged service model

Current `osascript ... with administrator privileges` is acceptable only as a
development bridge. Product model should be:

- App-owned temporary daemon for interactive sessions.
- Explicit system helper install/uninstall flow for persistent privileged
  operation.
- No static plist with personal paths.
- App exit must call shutdown for app-owned daemon.
- System helper must expose controlled commands and cleanup diagnostics.

### 5. Cleanup / safety invariants

These should remain hard rules:

- Do not write system DNS from the tunnel manager.
- Reject Fake-IP endpoint resolution before creating a tunnel.
- Do not create physical routes for Mihomo Fake-IP ranges.
- Default automation must be opt-in.
- App-owned daemon shutdown must disconnect before exit.
- Packaging must not contain user-specific absolute paths.

## Verification Used

- `go test ./...`
- `go vet ./...`
- `go test -race ./internal/policy ./internal/proxy ./internal/transfer ./api`
- `zsh -n` for packaging scripts
- `plutil -lint` for plist templates
- `git diff --check`

## Next Work Items

1. Extract `DaemonAPIClient` and typed endpoint helpers from
   `DaemonClient.swift`.
2. Move transfer models and methods from `DaemonClient.swift` into
   `TransferClient.swift`.
3. Move proxy models and methods into `ProxyClient.swift`.
4. Split `MainView.swift` dashboard tiles into feature files without changing
   behavior.
5. Split `ProxyView.swift` into tab/subview files.
6. Split Go API handlers into `core/api/core.go`, `profile.go`, `transfer.go`,
   `shutdown.go`, while keeping public routes stable.
