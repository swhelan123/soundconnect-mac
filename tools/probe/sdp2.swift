import Foundation
import IOBluetooth
let dev = IOBluetoothDevice(addressString: CommandLine.arguments[1])!
for case let rec as IOBluetoothSDPServiceRecord in dev.services ?? [] {
    var ch: BluetoothRFCOMMChannelID = 0
    let hasRF = rec.getRFCOMMChannelID(&ch) == kIOReturnSuccess
    let a = rec.getAttributeDataElement(1)
    print("ch", hasRF ? String(ch) : "-", rec.getServiceName() ?? "", a.map{ "\($0)" } ?? "nil")
}
