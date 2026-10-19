import AppKit
import IOBluetooth

/// `bt` lists paired Bluetooth devices; Return connects or disconnects one.
enum BluetoothDevices {
    static let keywords: Set<String> = ["bt", "bluetooth"]

    static func results(argument: String) -> [Result] {
        let f = argument.lowercased().trimmingCharacters(in: .whitespaces)
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return [Result(id: "bt:none", title: "No paired devices, or Bluetooth is off", subtitle: "Return opens Bluetooth settings",
                           icon: NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: nil),
                           action: .openPath("x-apple.systempreferences:com.apple.BluetoothSettings"))]
        }
        let devices = paired.filter { f.isEmpty || ($0.name ?? "").lowercased().contains(f) }
            .sorted { ($0.isConnected() ? 0 : 1, $0.name ?? "") < ($1.isConnected() ? 0 : 1, $1.name ?? "") }
        if devices.isEmpty {
            return [Result(id: "bt:nomatch", title: "No paired device matches", subtitle: nil, icon: nil, action: .none)]
        }
        return devices.map { d in
            let name = d.name ?? d.addressString ?? "Device"
            let connected = d.isConnected()
            return Result(id: "bt:\(d.addressString ?? name)", title: connected ? "Disconnect \(name)" : "Connect \(name)",
                          subtitle: connected ? "Connected" : "Paired, not connected",
                          icon: NSImage(systemSymbolName: connected ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash", accessibilityDescription: nil),
                          action: .custom {
                              DispatchQueue.global().async {
                                  let r = connected ? d.closeConnection() : d.openConnection()
                                  Log.write("bluetooth \(connected ? "disconnect" : "connect") \(name): \(r)")
                              }
                          })
        }
    }
}

extension BluetoothDevices {
    static var command: KeaCommand {
        KeaCommand(id: "bluetooth", name: "Bluetooth", keywords: keywords,
                   help: [.init(keyword: "bt", summary: "Connect or disconnect paired Bluetooth devices", example: "bt · bt airpods")],
                   results: { results(argument: $0.argument) })
    }
}
