// DesktopPlaneAgent.app's executable. It holds the guest's Accessibility and Screen Recording
// grants (macOS ties them to this binary's code identity) and runs the real agent as a child.
// Children are attributed to the app that spawned them, so the agent and arc-cua inherit the
// grants, and the agent can be updated without granting anything again.
//
// Keep this file tiny and unchanged: any edit changes the code identity and voids the grants.

import Foundation

let core = "/Library/Application Support/DesktopPlane/agent-core"
var child: pid_t = 0

for sig in [SIGTERM, SIGINT] {
    signal(sig) { s in
        if child > 0 { kill(child, s) }
        exit(0)
    }
}

while true {
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(core), nil]
    let rc = posix_spawn(&pid, core, nil, nil, argv, environ)
    if rc == 0 {
        child = pid
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        child = 0
        FileHandle.standardError.write(Data("agent-core exited (\(status)); restarting\n".utf8))
    } else {
        FileHandle.standardError.write(Data("cannot start \(core): \(String(cString: strerror(rc)))\n".utf8))
    }
    sleep(2)
}
