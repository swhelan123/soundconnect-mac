import Foundation
import IOBluetooth
setvbuf(stdout, nil, _IONBF, 0)

func frame(_ type: UInt8, _ seq: UInt8, _ payload: [UInt8]) -> [UInt8] {
    let n = UInt32(payload.count)
    var body: [UInt8] = [type, seq, UInt8(n>>24), UInt8((n>>16)&0xff), UInt8((n>>8)&0xff), UInt8(n&0xff)] + payload
    body.append(UInt8(body.reduce(0) { ($0 + Int($1)) } & 0xff))
    var out: [UInt8] = [0x3e]
    for b in body { if b == 0x3c || b == 0x3d || b == 0x3e { out += [0x3d, b & 0xef] } else { out.append(b) } }
    out.append(0x3c); return out
}
func hex(_ b: [UInt8]) -> String { b.map{String(format:"%02x",$0)}.joined(separator:" ") }

class D: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var ch: IOBluetoothRFCOMMChannel?
    func rfcommChannelOpenComplete(_ c: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        print("open status", status)
        var f = frame(0x0c, 0, [0x00, 0x00]); print("TX", hex(f))
        _ = c.writeSync(&f, length: UInt16(f.count))
    }
    func rfcommChannelData(_ c: IOBluetoothRFCOMMChannel!, data p: UnsafeMutableRawPointer!, length n: Int) {
        let b = [UInt8](UnsafeRawBufferPointer(start: p, count: n)); print("RX", hex(b))
        // ACK any data frame (type 0x01 ack, seq flipped)
        if b.count > 3 && b[1] != 0x01 { var a = frame(0x01, 1 &- b[2], []); _ = c.writeSync(&a, length: UInt16(a.count)) }
    }
    func rfcommChannelClosed(_ c: IOBluetoothRFCOMMChannel!) { print("closed") }
}
let want = CommandLine.arguments[1].lowercased().replacingOccurrences(of: ":", with: "-")
let dev = (IOBluetoothDevice.pairedDevices() as! [IOBluetoothDevice]).first { $0.addressString.lowercased() == want }!
print("dev", dev.name ?? "", dev.isConnected())
let d = D()
var chan: IOBluetoothRFCOMMChannel?
DispatchQueue.main.async {
    let r = dev.openRFCOMMChannelAsync(&chan, withChannelID: 9, delegate: d)
    print("openAsync", String(format:"0x%x", r))
}
RunLoop.main.run(until: Date().addingTimeInterval(15)); fflush(stdout)
chan?.close()
