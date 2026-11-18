import CMDR
import Foundation
import IOBluetooth

struct SonyDevice: Equatable {
    var name: String
    var address: String
    var serviceUUID: String
    var protocolVersion: MDRProtocolVersion
}

/// Finds a connected, paired Bluetooth Classic device that advertises Sony's MDR control service.
enum DeviceFinder {
    private static let candidates: [(uuid: String, proto: MDRProtocolVersion)] = [
        (MDR_SERVICE_UUID_V2, MDRProtocolVersion(MDR_PROTOCOL_V2)),
        (MDR_SERVICE_UUID_V1, MDRProtocolVersion(MDR_PROTOCOL_V1)),
    ]

    @MainActor
    static func findConnected() -> SonyDevice? {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return nil }
        for dev in paired where dev.isConnected() {
            if dev.services == nil { dev.performSDPQuery(nil) }
            for c in candidates {
                guard let sdp = sdpUUID(c.uuid), dev.getServiceRecord(for: sdp) != nil else { continue }
                return SonyDevice(name: dev.name ?? "Sony Headphones",
                                  address: dev.addressString ?? "",
                                  serviceUUID: c.uuid,
                                  protocolVersion: c.proto)
            }
        }
        return nil
    }

    /// Drop and re-establish the Bluetooth link. Clears a control channel that bluetoothd still
    /// considers in use (RFCOMM open fails instantly). Audio cuts out for a few seconds.
    @MainActor
    static func resetLink(address: String, completion: @escaping @MainActor () -> Void) {
        guard let dev = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?
            .first(where: { $0.addressString.lowercased() == address.lowercased() }) else { completion(); return }
        dev.closeConnection()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            dev.openConnection()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { completion() }
        }
    }

    private static func sdpUUID(_ s: String) -> IOBluetoothSDPUUID? {
        guard let u = UUID(uuidString: s) else { return nil }
        var bytes = u.uuid
        return withUnsafeBytes(of: &bytes) { IOBluetoothSDPUUID(bytes: $0.baseAddress, length: 16) }
    }
}
