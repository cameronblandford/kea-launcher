import XCTest
@testable import LauncherCore

final class ProcessesTests: XCTestCase {
    func testListeners() {
        let lsof = #"""
        COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        rapportd    700  me    13u  IPv4 0x4e827db78a3f8608      0t0  TCP *:64649 (LISTEN)
        rapportd    700  me    14u  IPv6 0xc571d6099d98c9e1      0t0  TCP *:64649 (LISTEN)
        node        837  me    47u  IPv6 0xf4f88260cc3b9a89      0t0  TCP [::1]:4321 (LISTEN)
        node        837  me    48u  IPv4 0xf4f88260cc3b9a80      0t0  TCP 127.0.0.1:4321 (LISTEN)
        Google\x20Chr 901 me   50u  IPv4 0xabc                  0t0  TCP 127.0.0.1:9222 (LISTEN)
        Discord\x20Helper\x20(Renderer) 950 me  51u IPv4 0xabd        0t0  TCP 127.0.0.1:6463 (LISTEN)
        garbage line
        """#
        let l = Processes.parseListeners(lsof)
        XCTAssertEqual(l.map(\.port), [4321, 6463, 9222, 64649])
        XCTAssertEqual(l[0], .init(command: "node", pid: 837, port: 4321, address: "[::1]"))
        XCTAssertEqual(l[1].command, "Discord Helper (Renderer)")   // `lsof +c 0` gives whole names
        XCTAssertEqual(l[2].command, "Google Chr")
        XCTAssertEqual(l[3].address, "*")
    }

    func testProcesses() {
        let ps = "    1   12345 /sbin/launchd\n  837  204800 /opt/homebrew/bin/node\n  901 1048576 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome\nbad\n"
        let p = Processes.parseProcesses(ps)
        XCTAssertEqual(p.count, 3)
        XCTAssertEqual(p[2].name, "Google Chrome")
        XCTAssertEqual(p[1].memory, 204800 * 1024)
        XCTAssertEqual(Processes.match(p, "chrome").map(\.pid), [901])
        XCTAssertEqual(Processes.match(p, "google chrome").map(\.pid), [901])
        XCTAssertEqual(Processes.match(p, "").count, 0)
    }
}
