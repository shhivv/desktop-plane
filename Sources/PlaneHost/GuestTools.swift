import Foundation

/// Stages the folder shared (read-only) with the VM while the image is provisioned. It shows up
/// in the guest as "/Volumes/My Shared Files". Runtime VMs never get it.
enum GuestTools {
    static var dir: URL { Paths.root.appendingPathComponent("guest-tools") }
    static let agentBundleName = "DesktopPlaneAgent.app"

    static func stage() throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try buildAgentBundle(at: dir.appendingPathComponent(agentBundleName))
        let script = dir.appendingPathComponent("install.sh")
        try installScript.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        try readme.write(to: dir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        return dir
    }

    /// Finds the GuestAgent build: inside the app bundle, or next to this executable (swift build).
    static func agentSource() throws -> URL {
        if let u = ProcessInfo.processInfo.environment["PLANE_GUEST_AGENT"] { return URL(fileURLWithPath: u) }
        if let app = Bundle.main.url(forResource: "DesktopPlaneAgent", withExtension: "app") { return app }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let sibling = exe.deletingLastPathComponent().appendingPathComponent("GuestAgent")
        if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        throw PlaneError("GuestAgent not found; build it with `swift build` or use the packaged app")
    }

    static func buildAgentBundle(at dest: URL) throws {
        let src = try agentSource()
        let fm = FileManager.default
        if src.pathExtension == "app" {
            try fm.copyItem(at: src, to: dest)
            return
        }
        let macos = dest.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.copyItem(at: src, to: macos.appendingPathComponent("GuestAgent"))
        try agentInfoPlist.write(to: dest.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        // Ad-hoc signature: gives TCC a stable code identity to grant permissions to.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--force", "--sign", "-", "--identifier", "dev.desktopplane.agent", dest.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw PlaneError("codesign of guest agent failed") }
    }

    static let agentInfoPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleIdentifier</key><string>dev.desktopplane.agent</string>
      <key>CFBundleName</key><string>Desktop Plane Agent</string>
      <key>CFBundleExecutable</key><string>GuestAgent</string>
      <key>CFBundlePackageType</key><string>APPL</string>
      <key>CFBundleShortVersionString</key><string>0.1.0</string>
      <key>CFBundleVersion</key><string>1</string>
      <key>LSMinimumSystemVersion</key><string>14.0</string>
      <key>LSUIElement</key><true/>
    </dict>
    </plist>
    """

    static let readme = """
    Desktop Plane guest setup
    =========================
    1. Finish Setup Assistant (create a local account, skip Apple ID).
    2. Open Terminal and run:
         bash "/Volumes/My Shared Files/install.sh"
    3. Shut the VM down from the Apple menu when it says Done.
    """

    static let installScript = #"""
    #!/bin/bash
    # Desktop Plane guest setup. Run inside the VM as your normal user:
    #   bash "/Volumes/My Shared Files/install.sh"
    set -euo pipefail
    TOOLS="$(cd "$(dirname "$0")" && pwd)"
    ARC_SPEC="${ARC_CUA_SPEC:-arc-cua[macos]}"
    ME="$(id -un)"
    AGENT_APP=/Applications/DesktopPlaneAgent.app
    LABEL=dev.desktopplane.agent
    STATUS="$HOME/Library/Application Support/DesktopPlaneAgent/status.json"

    step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
    if [ "$EUID" -eq 0 ]; then echo "Run this as your normal user, not with sudo."; exit 1; fi

    step "Admin password (for auto-login, power settings and clock sync)"
    read -r -s -p "Password for $ME: " PASS; echo
    printf '%s\n' "$PASS" | sudo -S -v 2>/dev/null || { echo "Wrong password."; exit 1; }

    step "Installing the guest agent"
    sudo rm -rf "$AGENT_APP"
    sudo cp -R "$TOOLS/DesktopPlaneAgent.app" "$AGENT_APP"
    sudo xattr -dr com.apple.quarantine "$AGENT_APP" 2>/dev/null || true

    step "Letting the agent set the clock after a snapshot restore"
    echo "$ME ALL=(root) NOPASSWD: /bin/date" | sudo tee /etc/sudoers.d/desktopplane >/dev/null
    sudo chmod 440 /etc/sudoers.d/desktopplane
    sudo visudo -cf /etc/sudoers.d/desktopplane >/dev/null

    step "Installing uv and $ARC_SPEC"
    if [ ! -x "$HOME/.local/bin/uv" ]; then
      curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh
    fi
    "$HOME/.local/bin/uv" tool install --force --python 3.12 "$ARC_SPEC"
    "$HOME/.local/bin/arc-cua" --help >/dev/null

    step "Auto-login, no sleep, no screen lock, no automatic updates"
    sudo sysadminctl -autologin set -userName "$ME" -password "$PASS"
    sudo sysadminctl -screenLock off -password "$PASS" 2>/dev/null || true
    sudo pmset -a sleep 0 displaysleep 0 disksleep 0 powernap 0 womp 0
    defaults -currentHost write com.apple.screensaver idleTime -int 0
    defaults write com.apple.loginwindow TALLogoutSavesState -bool false
    sudo softwareupdate --schedule off >/dev/null 2>&1 || true
    for k in AutomaticDownload AutomaticallyInstallMacOSUpdates CriticalUpdateInstall ConfigDataInstall; do
      sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate "$k" -bool false
    done
    unset PASS

    step "Starting the agent at every login"
    PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    cat > "$PLIST" <<PLIST
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>$LABEL</string>
      <key>ProgramArguments</key><array><string>$AGENT_APP/Contents/MacOS/GuestAgent</string></array>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><true/>
      <key>LimitLoadToSessionType</key><string>Aqua</string>
      <key>ProcessType</key><string>Interactive</string>
      <key>EnvironmentVariables</key><dict>
        <key>PATH</key><string>$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
      </dict>
      <key>StandardErrorPath</key><string>$HOME/Library/Logs/desktopplane-agent.log</string>
    </dict>
    </plist>
    PLIST
    launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$UID" "$PLIST"

    step "Permissions"
    echo "Turn on 'Desktop Plane Agent' (or GuestAgent) under BOTH:"
    echo "  Privacy & Security > Accessibility"
    echo "  Privacy & Security > Screen & System Audio Recording"
    echo "If it is not listed, click + and pick $AGENT_APP."
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    while true; do
      read -r -p "Press Return once both are on... " _
      launchctl kickstart -k "gui/$UID/$LABEL"
      sleep 3
      if grep -q '"accessibility" *: *true' "$STATUS" 2>/dev/null && grep -q '"screenRecording" *: *true' "$STATUS" 2>/dev/null; then
        echo "Both permissions granted."
        break
      fi
      echo "Agent status: $(cat "$STATUS" 2>/dev/null || echo 'not running')"
      echo "Not granted yet."
      open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    done

    step "Locking the network down (the VM's only way out becomes the host proxy)"
    SERVICE="$(networksetup -listallnetworkservices | sed 1d | grep -v '^\*' | head -1)"
    sudo networksetup -setmanual "$SERVICE" 10.0.2.15 255.255.255.0 10.0.2.2
    sudo networksetup -setdnsservers "$SERVICE" 10.0.2.2
    sudo networksetup -setv6off "$SERVICE"
    sudo networksetup -setwebproxy "$SERVICE" 127.0.0.1 3128
    sudo networksetup -setsecurewebproxy "$SERVICE" 127.0.0.1 3128
    sudo networksetup -setproxybypassdomains "$SERVICE" localhost 127.0.0.1 "*.local"

    step "Done"
    echo "Shut this VM down now (Apple menu > Shut Down). Desktop Plane will snapshot it."
    """#
}
