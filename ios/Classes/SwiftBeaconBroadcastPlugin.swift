import Flutter
import UIKit
import CoreBluetooth // Import for CBPeripheralManagerDelegate if you were to check states here, not strictly needed for this plugin structure

public class SwiftBeaconBroadcastPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private var beacon = Beacon()
    private var eventSink: FlutterEventSink?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = SwiftBeaconBroadcastPlugin()

        let methodChannel = FlutterMethodChannel(name: "pl.pszklarska.beaconbroadcast/beacon_state", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        let beaconEventChannel = FlutterEventChannel(name: "pl.pszklarska.beaconbroadcast/beacon_events", binaryMessenger: registrar.messenger())
        beaconEventChannel.setStreamHandler(instance)

        // Setup listener after eventSink can be captured by onListen
        // instance.registerBeaconListener() // Moved this call to onListen
    }

    // Called when Flutter starts listening
    public func onListen(withArguments arguments: Any?,
                         eventSink: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = eventSink
        registerBeaconListener() // Register the native listener now that we have the sink
        // You might want to send an initial state if known, e.g., beacon.isAdvertising()
        // self.eventSink?(beacon.isAdvertising())
        return nil
    }

    // Connects the Beacon's state changes to the Flutter event sink
    func registerBeaconListener() {
        beacon.onAdvertisingStateChanged = { [weak self] isAdvertising in
            guard let self = self else { return }
            if (self.eventSink != nil) {
                print("Plugin: Sending advertising state to Flutter: \(isAdvertising)")
                self.eventSink!(isAdvertising)
            } else {
                print("Plugin: EventSink is nil, cannot send advertising state.")
            }
        }
    }

    // Called when Flutter stops listening
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        print("Plugin: Flutter cancelled event stream. Clearing eventSink.")
        eventSink = nil
        // It's good practice to also remove the listener from the beacon object
        // if it could be resource-intensive or to prevent retain cycles if not using [weak self]
        // beacon.onAdvertisingStateChanged = nil // Though with [weak self] this might not be strictly necessary
        return nil
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        print("Plugin: Received method call: \(call.method)")
        switch (call.method) {
        case "start":
            startBeacon(call, result)
        case "startCyclical": // New method
            startCyclicalBeacon(call, result)
        case "stop":
            stopBeacon(call, result)
        case "isAdvertising":
            isAdvertising(call, result)
        case "isTransmissionSupported": // This still returns a static value
            isTransmissionSupported(call, result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func parseBeaconData(fromArguments arguments: Any?) -> BeaconData? {
        guard let map = arguments as? Dictionary<String, Any>,
              let uuid = map["uuid"] as? String,
              let majorId = map["majorId"] as? NSNumber,
              let minorId = map["minorId"] as? NSNumber,
              let identifier = map["identifier"] as? String else {
            return nil
        }
        let transmissionPower = map["transmissionPower"] as? NSNumber

        return BeaconData(
            uuid: uuid,
            majorId: majorId,
            minorId: minorId,
            transmissionPower: transmissionPower,
            identifier: identifier
        )
    }

    private func startBeacon(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let beaconDataObj = parseBeaconData(fromArguments: call.arguments) else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing or invalid arguments for start", details: nil))
            return
        }
        beacon.start(beaconData: beaconDataObj)
        result(nil)
    }

    private func startCyclicalBeacon(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let map = call.arguments as? Dictionary<String, Any>,
              let beaconDataObj = parseBeaconData(fromArguments: call.arguments), // Reuse parser
              let advertisingDuration = map["advertisingDuration"] as? Double,    // in seconds
              let pauseDuration = map["pauseDuration"] as? Double else {         // in seconds
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing or invalid arguments for startCyclical (durations or beacon data)", details: nil))
            return
        }

        if advertisingDuration <= 0 {
             result(FlutterError(code: "INVALID_ARGUMENTS", message: "advertisingDuration must be positive", details: nil))
            return
        }

        beacon.startCyclical(beaconData: beaconDataObj,
                             advertisingDuration: TimeInterval(advertisingDuration),
                             pauseDuration: TimeInterval(pauseDuration))
        result(nil)
    }

    private func stopBeacon(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        beacon.stop()
        result(nil)
    }

    private func isAdvertising(_ call: FlutterMethodCall,
                               _ result: @escaping FlutterResult) {
        result(beacon.isAdvertising())
    }

    private func isTransmissionSupported(_ call: FlutterMethodCall,
                               _ result: @escaping FlutterResult) {
        // This is a simplified check. For a real check:
        // let manager = CBPeripheralManager(delegate: nil, queue: nil)
        // switch manager.state {
        // case .unsupported, .unauthorized, .poweredOff: result(FlutterError... or specific int code)
        // default: result(0) // or specific "supported" int code
        // }
        // However, creating a CBPeripheralManager just for this check might be overkill
        // if you are already creating one in the Beacon class.
        // For now, it returns the previous static value.
        result(0) // Assuming 0 means supported or default.
    }
}