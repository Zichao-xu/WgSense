# WgSense Button Audit

Last updated: 2026-07-15

Goal: every visible control should either complete a real backend action with
loading/error/success feedback, or clearly present itself as read-only.

## Completed

- Sidebar tile grid: replaced ad-hoc `VStack/HStack` packing with a dedicated
  AppKit `NSCollectionView` with a custom `NSCollectionViewLayout`; the outer
  divider now uses native `HSplitView`/`NSSplitView` resizing. User confirmed
  dragging no longer jitters. Column reflow and tile resizing use native
  collection-layout transitions and respect the system Reduce Motion setting.
- Liquid Glass: added the system macOS 26 `glassEffect` to functional layers
  only: the sidebar toolbar, proxy section navigation, and the transient tile
  editing bar. macOS 14-15 use native Material fallback. The AppKit tile grid
  and dense content cards deliberately remain outside glass capture layers to
  preserve redraw stability and legibility.
- Sidebar resize: column count is held stable while dragging and only settles
  after resize ends, avoiding continuous column flip jitter.
- Sidebar launch width: the native split divider now starts at a 260 px
  standard width instead of allowing `HSplitView` to expand it to the 560 px
  maximum. Real divider drags update the in-memory target, while page changes
  preserve that target. The AppKit collection document now autoresizes with
  its viewport so programmatic and interactive width changes reflow every tile
  instead of clipping offscreen columns.
- Settings: "应用配置到 daemon" now reports success/failure and disables while
  applying.
- Transfer receive service:
  - added daemon APIs: `POST /api/transfer/start`, `POST /api/transfer/stop`;
  - settings page toggle now starts/stops the service;
  - receive page toggle now starts/stops the service;
  - replaced LocalGo's terminal-only prompt with a daemon pending-request queue;
  - receive page now polls pending requests and has real accept/reject actions.
- Transfer send: manual devices now have a visible remove button; the Swift
  client now respects the backend `{"ok": false}` response. Official LocalSend
  v2 discovery now uses UDP/TCP 53317, emits both official `announcement` and
  legacy `announce` fields with protocol version 2.1, and uses
  `POST /api/localsend/v2/register`. It retains HTTP/HTTPS, bridges inbound
  registrations into the daemon cache, caches multicast/scan/manual devices,
  and surfaces backend errors instead of collapsing them to an empty list.
- Proxy page:
  - replaced the partial page with native Overview, Proxies, Connections, Rules,
    Logs, and Settings workspaces backed by the real Mihomo API;
  - integrated the workspace into the app's main split view, removed the nested
    navigation rail and outer scroll view, and scoped polling to the visible
    proxy subpage so unrelated WireGuard updates no longer invalidate large
    proxy lists;
  - added a default-on Apple Color Emoji setting and native country/category
    markers without loading a web font or duplicating existing node emoji;
  - mode, TUN, LAN, IPv6, ports, provider update/healthcheck, rule provider,
    DNS query, cache maintenance, connection close, and delay actions report
    loading/error/success state;
  - provider responses retain counts but omit redundant embedded node arrays,
    reducing the live response from about 188 KB to 6.9 KB.
- Privileged daemon startup:
  - network actions first test the local API, then immediately show the macOS
    administrator authorization dialog when root startup is required;
  - daemon startup is detached instead of waiting forever for the foreground
    process, authorization can be retried, and buttons show an authorizing state;
  - authorized startup passes the login user's runtime directory explicitly so
    profiles, LocalSend identity, and proxy settings do not move to `/var/root`;
  - removed the hard-coded Mihomo secret from the app source.
  - installed the current daemon as the enabled root LaunchDaemon
    `com.wgsense.daemon` with `RunAtLoad` and `KeepAlive`; killing the process
    twice produced a new PID and restored the API in under a second.
  - removed the temporary user-level passive daemon. Status now exposes
    `passive`, and connect requests are rejected if an API-only daemon is ever
    started accidentally.
- WireGuard actions:
  - POST actions now await their HTTP request instead of returning while a
    detached task is still running, preserving resume/connect order;
  - transient health-check failures require three consecutive failures at the
    configured interval before reconnecting, protecting long-lived sessions;
  - removed the physical-interface route for Mihomo's `198.18.0.0/15` Fake-IP
    range, which made AI endpoints unreachable when WgSense WG was active.
  - verified the installed profile has one complete interface/peer, a resolvable
    endpoint, and an address outside the configured home prefix. The live root
    policy checks every 10 seconds, remains disconnected on configured trusted networks, and
    the away-network branch is covered by unit and race tests.
  - after the 2026-07-16 office incident, away-network auto-connect is now
    disabled by default. Endpoint DNS results in `198.18.0.0/15` are treated as
    Mihomo/Clash Fake-IP and rejected before TUN creation. Failed auto-connects
    back off instead of creating a new utun every policy tick.
- Profiles:
  - switch/save/delete/edit now surface disk, daemon, and permission failures
    instead of silently swallowing them.
- Overview:
  - transfer and proxy module rows now load and show real backend state.
- Transfer landing:
  - the root daemon receives into
    `~/.local/share/wgsense/incoming`, avoiding macOS TCC denial on Downloads;
  - the user LaunchAgent `com.wgsense.receive-mover` waits until the receive
    file is closed, copies through a hidden temporary file, atomically publishes
    it to `~/Downloads/WgSense`, and leaves a user-owned `0644` file;
  - an end-to-end root-owned probe passed content, ownership, cleanup, and
    restart checks without leaving partial files.

## Needs Follow-Up

- Controlled away-network WG test:
  - A real handshake must now be performed only with auto-connect explicitly
    enabled and Fake-IP DNS disabled or bypassed for the WireGuard endpoint.
    Confirm the tunnel handshake, sustain a long AI Agent conversation through
    Mihomo, then disconnect and verify route cleanup.

- Profile switch/delete:
  - Add a persistent inline progress row during disconnect/reconnect; failures
    are now reported and no longer silent.
- Settings:
  - Validate daemon config persistence and reload behavior after `/api/config`.
  - Add field validation for URL, intervals, and network prefixes.
- Transfer:
  - Alias/download directory remain read-only until the backend exposes safe
    persistence; file send/receive progress, cancellation, approval, history,
    and errors are implemented.
  - Text/clipboard sends remain hidden until the backend supports them.
- Logs:
  - Split daemon/proxy/transfer logs if backend exposes separate streams.
  - Add copy/export for selected errors.
