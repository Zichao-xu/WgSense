# WgSense Network Incident 2026-07-16

## Cause

At the office network, WgSense was running as a root LaunchDaemon with automatic
away-network connection enabled. The system resolver returned a Mihomo/Clash
Fake-IP for the WireGuard endpoint:

`ddns.aminoac.icu:51820 -> 198.18.1.6`

WgSense treated that Fake-IP as the real endpoint and added a physical exclusion
route for it. WireGuard then attempted to handshake with a local proxy synthetic
address, failed, cleaned up, and retried on the next policy tick. Each retry
created a new utun before handshake timeout, which made the network state appear
stuck and unreliable.

## Fix

- `198.18.0.0/15` endpoint resolutions are rejected before TUN creation.
- Away-network auto-connect is disabled by default and must be explicitly
  enabled.
- Auto-connect failures use backoff instead of retrying every policy tick.
- App-started daemon instances are marked `app_owned=true` and accept
  `/api/shutdown`; system LaunchDaemon instances reject that shutdown path.
- The packaged LaunchDaemon no longer uses `KeepAlive` and starts with
  `--auto-connect-away=false`.
- `packaging/wgsense-uninstall-services.sh` removes installed WgSense services
  and helper binaries without deleting user profiles or transfer data.

## Current Safety State

On 2026-07-16, no WgSense LaunchDaemon, LaunchAgent, API listener, or WgSense
process was running when inspected. The active IPv4 default route was physical
Wi-Fi `en0` via `10.10.1.1`. Existing `utun0`-`utun3` had only IPv6 link-local
addresses and were not WgSense processes.
