# Desktop Plane

Turn a spare Apple Silicon Mac into an on-demand pool of throwaway macOS desktops for
computer-use agents. Each desktop is a fresh macOS VM (Apple Virtualization.framework) with
the [arc-cua](https://github.com/shhivv/arc-cua) driver inside, reachable as an MCP server.

Your agents keep running on your own computer. The spare Mac only serves desktops: when an
agent needs a screen, it starts one there over MCP, drives it, and ends it. Any agent that
supports MCP over Streamable HTTP works; coding agents like Claude Code and Codex are one good
fit. The app walks you through making the Mac reachable (Tailscale, or your local network) and
shows the URL and header to add. For Claude Code, that's:

```bash
# on your computer
claude mcp add --scope user --transport http desktop-plane https://<mac>.<tailnet>.ts.net/v1/mcp \
  --header "Authorization: Bearer <token>"
claude "Start a desktop with Safari, open apple.com and tell me the headline."
```

- **Fast:** a desktop restores from a saved snapshot of an APFS copy-on-write clone in about 6–9 seconds. A second desktop started while one is running cold boots in about 15–20 seconds (see below).
- **Throwaway:** each session gets its own clone; ending it deletes the clone. Nothing carries over.
- **Isolated:** VMs have no route to each other, the host, or your LAN (see below).
- **One Swift package, no dependencies:** a menu bar app, a headless daemon, and a tiny guest agent.

> macOS runs at most **2 macOS VMs at once per Mac**, so one Mac gives you 2 desktops.
> Add Macs to get more.

## Requirements

- Apple Silicon Mac, macOS 14 or later (built and tested on macOS 26)
- About 60 GB free disk (the macOS download and the image)
- 16 GB of memory or more for two desktops at once; 8 GB runs one. Desktop size is set from
  this Mac's memory on first launch.
- Xcode 16+ command line tools, only to build from source

## Set up

Download the DMG from [Releases](https://github.com/shhivv/desktop-plane/releases), drag
Desktop Plane to Applications and open it. Or build it yourself:

```bash
scripts/bundle.sh                     # builds and signs "dist/Desktop Plane.app" (ad hoc)
open "dist/Desktop Plane.app"
```

The first run walks you through building the golden image once and connecting your agent:

1. **Install macOS.** Downloads the latest supported restore image (about 17 GB) and installs it.
   Allow 20–40 minutes, mostly the download.
2. **Set up.** The VM appears in the window. Finish Setup Assistant with a local account (skip the
   Apple ID). Then open Terminal in the VM and type (there is no shared clipboard):
   ```bash
   bash "/Volumes/My Shared Files/install.sh"
   ```
   The script:
   - installs the guest agent and arc-cua;
   - turns on auto-login and turns off sleep and updates;
   - walks you through granting **Accessibility** and **Screen Recording** to *Desktop Plane Agent*;
   - locks the VM's network down.

   When it says Done, shut the VM down from the Apple menu.
3. **Snapshot.** Boots the image in its locked-down runtime configuration, checks the agent,
   and saves the machine state every desktop restores from. It also keeps a cleanly shut-down copy of the disk.

   Only one VM restored from a snapshot can run per machine identity, and giving a second VM
   its own identity makes macOS treat it as a new Mac and show Setup Assistant. So the first
   running desktop restores the snapshot, and one started while it runs cold boots from the
   clean copy.
4. **Network access.** Choose how your computer reaches this Mac: Tailscale (recommended;
   encrypted, works anywhere) or the same local network (plain HTTP).
5. **Connect.** The app shows the MCP URL and header to add to your agent on your computer.

Turn on **Open at login** in Settings so the Mac keeps serving desktops after a restart, and
turn on automatic login for its user account.

`planed`, the command-line host used below, ships inside the app. To use it from a terminal:

```bash
sudo ln -s "/Applications/Desktop Plane.app/Contents/MacOS/planed" /usr/local/bin/planed
```

Headless alternative (same engine): `planed image install`, `planed image provision`,
`planed image finalize`, then `planed serve`. `scripts/dev.sh <args>` runs a debug build of
`planed` with the needed entitlement.

### Settings

Set VM size and host options in the app's **Settings** section or with `planed config`. Both
write `~/Library/Application Support/DesktopPlane/settings.json`, and a running host picks up
changes within 2 seconds.

```bash
planed config                                  # show settings and what this Mac has
planed config set cpus=6 memory=12 slots=2     # VM size, desktops running at once
planed config set disk=120                     # disk size for the next image install
planed config set ttl=3600 idle=900 port=7480 bind=127.0.0.1
```

CPU and memory are part of the snapshot, so changing them means re-running step 3 (about a
couple of minutes). Disk size applies when the image is installed. The address and port apply
immediately.

### Updating the guest agent

Inside the guest, `DesktopPlaneAgent.app` is a tiny launcher that holds the Accessibility and
Screen Recording grants, and it runs the agent itself (`agent-core`) as a child that inherits
them. To update the agent in an existing image without booting it or granting anything again:

```bash
planed image update-agent && planed image finalize
```

## Use

### With an agent

Desktop Plane is one MCP server at `/v1/mcp` that you add once, in your agent's settings on the
computer where it runs. Use the URL and `Authorization` header from the app's **Agents** tab
(Streamable HTTP transport). Your agent gets tools to start,
list, screenshot and end desktops (`desktop_create`, `desktop_list`, `desktop_screenshot`,
`desktop_end`), `desktop_open` to launch apps or URLs, and the arc-cua driver's tools
(`observe`, `act`, `type_text`, `click_at`, …). Driver tools take an optional `desktop` id and
can leave it out while they have one desktop.

```bash
planed mcp                      # the URL, the header, and commands for Claude Code and Codex
planed mcp claude               # just the Claude Code command, to run on your computer
planed mcp install claude       # add it to Claude Code on this Mac (also: codex)
```

The driver's tool list is read from the image when its snapshot is saved, never from a running
desktop. `desktop_call` calls any driver tool by name.

### From another machine

The app's **Network access** setting does this for you. By hand, keep the API on loopback and
put Tailscale in front of it on the API's own port:

```bash
tailscale serve --bg --https=7480 http://127.0.0.1:7480
planed config set public-url=https://<mac>.<tailnet>.ts.net:7480
planed mcp claude                                           # run the printed command on the other machine
```

If your tailnet hasn't used Serve before, Tailscale asks you to turn it on in the admin console
first; the app shows the link.

### Sessions by hand

```bash
planed session new --open Safari --open https://example.com --ttl 1800
planed session list
planed session end ses_…
```

### HTTP API

```bash
TOKEN=$(planed token)
curl -s -X POST localhost:7480/v1/sessions -H "Authorization: Bearer $TOKEN" \
  -d '{"ttl_seconds": 3600, "network": {"allow": ["github.com"], "ports": [443]}}'
# -> {"id": "ses_…", "token": "dpt_…", "mcp_url": "http://127.0.0.1:7480/v1/sessions/ses_…/mcp", …}

claude mcp add --transport http desk "$MCP_URL" --header "Authorization: Bearer $SESSION_TOKEN"
```

| Method | Path | Auth | |
|---|---|---|---|
| GET | `/v1/health` | none | image stage, free slots |
| POST / DELETE | `/v1/mcp` | admin | the plane's MCP server (see above) |
| POST | `/v1/sessions` | admin | `ttl_seconds`, `idle_timeout_seconds`, `network: {enabled, allow, deny, ports}`, `volume`, `open` |
| GET | `/v1/sessions` | admin | list |
| GET / DELETE | `/v1/sessions/:id` | admin or session | |
| POST / DELETE | `/v1/sessions/:id/mcp` | admin or session | MCP Streamable HTTP |
| GET | `/v1/sessions/:id/screenshot` | admin or session | PNG |
| POST | `/v1/volumes` | admin | `name`, `size_gb` (default 10) |
| GET | `/v1/volumes`, `/v1/volumes/:id` | admin | size, bytes used, `attached_to` |
| DELETE | `/v1/volumes/:id` | admin | refused while attached |

arc-cua acts on windows that are already open and can't launch apps itself, so pass
`"open": ["Safari", "https://example.com"]` to start a desktop with apps or pages open. Each
entry is an app name or a URL, up to 10.

The image turns off autocorrect, auto-capitalization and smart punctuation, so text an agent
types arrives exactly as sent.

A session ends when it is deleted, when its TTL passes, after its idle timeout (no MCP or
network activity), or when the guest shuts down.

### Data volumes

Desktops are always fresh, but a **volume** can carry data from one session to the next, e.g.
a browser profile, downloads, or work files:

```bash
curl -s -X POST localhost:7480/v1/volumes -H "Authorization: Bearer $TOKEN" -d '{"name": "alice", "size_gb": 20}'
# -> {"id": "vol_…", …}
curl -s -X POST localhost:7480/v1/sessions -H "Authorization: Bearer $TOKEN" -d '{"volume": "vol_…"}'
```

The session boots from the snapshot as usual. Then the volume is plugged in as a USB drive
and mounts at `/Volumes/Data`. When the session ends, the guest ejects it cleanly and the VM is
destroyed. Only what is on the volume survives. Rules:
- one session per volume at a time;
- a volume in use can't be deleted;
- the files are sparse, so a volume takes up only what has been written to it.

Point apps at the volume to keep their data. For example, start Chrome with
`--user-data-dir=/Volumes/Data/chrome` to keep logins. Data that apps keep in system locations,
such as the macOS keychain, doesn't carry over.

Volumes need macOS 15 or later on the host.

From the menu bar you can **Watch** any desktop live. Watching blocks your input; **Take Control**
lets you use the desktop yourself.

`guestMCPCommand` in settings.json runs something other than `arc-cua mcp` per MCP session.

## Isolation model

The design assumes the code running in a guest is hostile.

| Path | What stops it |
|---|---|
| VM → another VM | No shared network. Each VM's NIC is one end of its own socket pair, owned by the host process. The other end only answers ARP and refuses everything else (TCP resets, ICMP unreachable). Nothing is forwarded, so there is no L2 or L3 path between VMs. Every VM uses the same addresses, 10.0.2.15 → 10.0.2.2. |
| VM → host / LAN / metadata | The only way out is the **egress proxy**, reached over the VM's own vsock device. It resolves names itself, refuses every non-public address (RFC 1918, loopback, link-local, CGNAT, ULA, IPv4-mapped, NAT64, …), and connects to the exact address it checked. DNS rebinding can't get through. |
| VM → internet | Per-session policy: `enabled`, `allow`/`deny` host patterns, and `ports` (default 80/443). Every connection is logged with its session id. |
| Tenant → another tenant's session | Each session token opens its own session only. Asking for another session gives the same 404 as a missing one. Only the admin token can create or list sessions. MCP session ids are scoped to their session. |
| Next tenant → previous tenant's data | VMs are never reused. Every session restores a fresh clone of the read-only golden image, and teardown deletes the clone. |
| Web page → local API | Requests with a non-local `Origin` are refused, and the API binds to loopback by default. |
| VM → host files / clipboard / devices | Runtime VMs have no shared folders, clipboard, audio or Rosetta. The guest-tools share exists only while the image is provisioned. The only USB device is the session's own data volume, if it asked for one. |
| Volume → host kernel | The host formats a volume once, when it creates it, while the file holds nothing but what the host wrote. After that only guests mount it. A guest could write a malformed filesystem, so the host never parses it. |
| Volume → another tenant | A volume attaches to one session at a time, chosen by the admin. Other sessions never see it. |

The guest's system proxy is `127.0.0.1:3128`, a forwarder in the agent that pipes to the host
over vsock. Apps that ignore the system proxy (raw sockets, UDP/QUIC) get no network.

`planed selftest` boots two desktops and checks all of the above from inside a real guest:
- direct internet access and host access fail;
- the proxy refuses loopback, LAN, metadata and rebinding addresses;
- tokens and MCP sessions don't cross sessions;
- clocks are synced after restore;
- files are deleted on teardown;
- volume data survives into a new session while everything else is gone, and a volume can't attach to two sessions or be deleted while in use.

## Layout

```
Sources/PlaneCore      wire formats, egress policy, dead-end LAN packets (unit-tested)
Sources/PlaneHost      VMs, image builder, sessions, egress proxy, HTTP API, self-test
Sources/planed         headless host + image CLI
Sources/DesktopPlane   SwiftUI menu bar app
Sources/AgentLauncher  guest launcher app that holds the guest's permissions (kept unchanged)
Sources/GuestAgent     agent inside each VM: vsock control, MCP, screenshots, proxy forwarder
```

## Licensing note

Apple's macOS license allows up to two additional macOS instances in VMs on a Mac you run,
for purposes including development and testing. Read it before offering desktops to third
parties.
