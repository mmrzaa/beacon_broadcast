import Foundation
import CoreBluetooth
import CoreLocation

// Data class (no changes)
public class BeaconData: NSObject {
    let uuid: String
    let majorId: NSNumber
    let minorId: NSNumber
    let transmissionPower: NSNumber?
    let identifier: String

    public init(uuid: String, majorId: NSNumber, minorId: NSNumber, transmissionPower: NSNumber?, identifier: String) {
        self.uuid = uuid
        self.majorId = majorId
        self.minorId = minorId
        self.transmissionPower = transmissionPower
        self.identifier = identifier
    }
}

public class Beacon: NSObject, CBPeripheralManagerDelegate {

    private var peripheralManager: CBPeripheralManager!
    // This will hold the iBeacon formatted data.
    // It should be freshly prepared before each startAdvertising call if there's any doubt.
    private var iBeaconAdvertisingPayload: NSDictionary!

    public var onAdvertisingStateChanged: ((Bool) -> Void)?

    private var shouldStartStandardAdvertising: Bool = false

    private var cyclicalAdvertisingTimer: Timer?
    private var originalBeaconDataForCycle: BeaconData? // Store the initial data for the cycle
    private var advertisingDurationForCycle: TimeInterval?
    private var pauseDurationForCycle: TimeInterval?
    private var isCurrentlyInCyclicalAdvertisingPhase: Bool = false
    private var isCyclicalModeActive: Bool = false

    public override init() {
        super.init()
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        print("Beacon: Initialized with CBPeripheralManager.")
    }

    // This function is CRITICAL for ensuring correct iBeacon format
    private func generateiBeaconPayload(for beaconData: BeaconData) -> NSDictionary? {
        guard let proximityUUID = UUID(uuidString: beaconData.uuid) else {
            print("Beacon Error: Invalid UUID string '\(beaconData.uuid)' for iBeacon payload.")
            return nil
        }
        let major = beaconData.majorId.uint16Value
        let minor = beaconData.minorId.uint16Value
        // Using the compatible CLBeaconRegion initializer
        let region = CLBeaconRegion(proximityUUID: proximityUUID, major: major, minor: minor, identifier: beaconData.identifier)

        // This is what creates the actual iBeacon advertisement data structure
        let payload = region.peripheralData(withMeasuredPower: beaconData.transmissionPower)
        print("Beacon: Generated iBeacon Payload: \(payload as? [String: Any] ?? [:])") // Log the payload
        return payload
    }

    public func start(beaconData: BeaconData) {
        print("Beacon: Standard start requested.")
        stopInternal(informListener: true)

        self.iBeaconAdvertisingPayload = generateiBeaconPayload(for: beaconData)
        if self.iBeaconAdvertisingPayload == nil {
            onAdvertisingStateChanged?(false)
            return
        }

        self.isCyclicalModeActive = false
        self.shouldStartStandardAdvertising = true

        if peripheralManager.state == .poweredOn {
            print("Beacon: Manager powered on, attempting standard start.")
            attemptToStartAdvertisingNow()
        } else {
            print("Beacon: Manager not powered on for standard start. Will wait.")
        }
    }

    public func startCyclical(beaconData: BeaconData, advertisingDuration: TimeInterval, pauseDuration: TimeInterval) {
        print("Beacon: Cyclical start requested. AdvTime: \(advertisingDuration), PauseTime: \(pauseDuration)")
        stopInternal(informListener: true)

        // Store the original data. We'll generate the payload just before each advertising attempt.
        self.originalBeaconDataForCycle = beaconData
        // Generate it once initially as well
        self.iBeaconAdvertisingPayload = generateiBeaconPayload(for: beaconData)
        if self.iBeaconAdvertisingPayload == nil {
             onAdvertisingStateChanged?(false)
             return
        }

        self.advertisingDurationForCycle = advertisingDuration
        self.pauseDurationForCycle = pauseDuration
        self.isCyclicalModeActive = true
        self.shouldStartStandardAdvertising = false
        self.isCurrentlyInCyclicalAdvertisingPhase = false // Will be set true when advertising starts

        if peripheralManager.state == .poweredOn {
            print("Beacon: Manager powered on, initiating first advertising phase of cycle.")
            // Directly set to true because we intend to start advertising phase first
            self.isCurrentlyInCyclicalAdvertisingPhase = true
            initiateNextCyclicalStep()
        } else {
            print("Beacon: Manager not powered on for cyclical start. Will wait.")
        }
    }

    private func attemptToStartAdvertisingNow() {
        guard peripheralManager.state == .poweredOn else {
            print("Beacon Error: Attempted to start advertising but manager not powered on.")
            return
        }

        // CRITICAL: Ensure iBeaconAdvertisingPayload is fresh and valid iBeacon data
        // If it's a cyclical start, originalBeaconDataForCycle should be available.
        if isCyclicalModeActive {
            guard let dataForCycle = originalBeaconDataForCycle else {
                print("Beacon Error: In cycle, but originalBeaconDataForCycle is nil. Stopping cycle.")
                stopInternal(informListener: true)
                return
            }
            // Re-generate the payload before each advertising attempt in a cycle
            // to be absolutely sure it's correct iBeacon format.
            self.iBeaconAdvertisingPayload = generateiBeaconPayload(for: dataForCycle)
        } // For standard start, it's set in start()

        guard iBeaconAdvertisingPayload != nil else {
            print("Beacon Error: Attempted to start advertising but iBeaconAdvertisingPayload is nil.")
            onAdvertisingStateChanged?(false)
            if isCyclicalModeActive { stopInternal(informListener: false) } // Stop cycle if data invalid
            return
        }

        if !peripheralManager.isAdvertising {
            print("Beacon: Calling peripheralManager.startAdvertising() with payload: \(iBeaconAdvertisingPayload as? [String: Any] ?? [:])")
            peripheralManager.startAdvertising(((iBeaconAdvertisingPayload as NSDictionary) as! [String : Any]))
        } else {
            // If we are already advertising, and this is a cyclical restart with the SAME data,
            // we might not need to do anything. However, to ensure 10Hz by stop/start, we would stop first.
            // The current logic in initiateNextCyclicalStep handles stopping first if it's a transition.
            print("Beacon: Already advertising. (attemptToStartAdvertisingNow)")
        }
    }

    public func stop() {
        print("Beacon: Public stop() called.")
        stopInternal(informListener: true)
    }

    private func stopInternal(informListener: Bool) {
        print("Beacon: stopInternal called. Inform listener: \(informListener)")
        cyclicalAdvertisingTimer?.invalidate()
        cyclicalAdvertisingTimer = nil

        isCyclicalModeActive = false
        shouldStartStandardAdvertising = false
        isCurrentlyInCyclicalAdvertisingPhase = false // Reset phase

        // Don't nil out iBeaconAdvertisingPayload here if a quick stop/start might reuse it,
        // but it will be regenerated in attemptToStartAdvertisingNow for cycles.

        if peripheralManager.isAdvertising {
            print("Beacon: Calling peripheralManager.stopAdvertising().")
            peripheralManager.stopAdvertising()
            if informListener {
                // Defer slightly, as isAdvertising might not update instantly
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { // Small delay
                     self.onAdvertisingStateChanged?(self.peripheralManager.isAdvertising)
                }
            }
        } else {
            if informListener {
                 self.onAdvertisingStateChanged?(false) // Already not advertising
            }
        }
    }

    public func isAdvertising() -> Bool {
        return peripheralManager.isAdvertising
    }

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        print("Beacon: Manager state updated to: \(peripheral.state.rawValue)")
        switch peripheral.state {
        case .poweredOn:
            print("Beacon: Manager powered ON.")
            if shouldStartStandardAdvertising {
                print("Beacon: Resuming standard advertising.")
                attemptToStartAdvertisingNow()
            } else if isCyclicalModeActive {
                print("Beacon: Manager powered ON during active cyclical mode. Re-evaluating cycle step.")
                // If it was supposed to be advertising, try to start.
                // If it was supposed to be in pause, the timer logic will handle it or re-initiate.
                // It's safer to re-initiate the current intended step.
                initiateNextCyclicalStep()
            }
        default:
            print("Beacon: Manager state changed to non-operational: \(peripheral.state.rawValue). Stopping activities.")
            stopInternal(informListener: true)
        }
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error = error {
            print("Beacon: Error during advertising operation: \(error.localizedDescription)")
            // This delegate can be called after a failed start or after a stop.
            // Ensure our internal state and listener reflect reality.
            self.onAdvertisingStateChanged?(false)
            if isCyclicalModeActive {
                print("Beacon: Cyclical advertising phase failed or was stopped. Halting cycle.")
                // Don't call stopInternal again if this error came from stopInternal's stopAdvertising,
                // to avoid loops. But if it's a start failure, stopping the cycle is good.
                // Check if we are still in an intended advertising phase to decide.
                if isCurrentlyInCyclicalAdvertisingPhase {
                    stopInternal(informListener: false) // Already informed false
                }
            }
        } else {
            // Successfully started advertising
            print("Beacon: Successfully started advertising (peripheralManager.isAdvertising is \(peripheral.isAdvertising)).")
            self.onAdvertisingStateChanged?(true)

            if isCyclicalModeActive && isCurrentlyInCyclicalAdvertisingPhase {
                if let advDuration = self.advertisingDurationForCycle, advDuration > 0 {
                    print("Beacon: Cyclical ON phase started. Scheduling end in \(advDuration)s.")
                    cyclicalAdvertisingTimer?.invalidate()
                    cyclicalAdvertisingTimer = Timer.scheduledTimer(
                        timeInterval: advDuration,
                        target: self,
                        selector: #selector(handleCyclicalTimerEvent),
                        userInfo: nil, // Not strictly needed anymore
                        repeats: false
                    )
                } else if let advDuration = self.advertisingDurationForCycle, advDuration <= 0 {
                    // ON duration is 0, so immediately go to OFF phase.
                    print("Beacon: Cyclical ON phase has duration <= 0. Proceeding to PAUSE phase immediately.")
                    // This will toggle isCurrentlyInCyclicalAdvertisingPhase to false and call initiateNextCyclicalStep
                    handleCyclicalTimerEvent(timer: Timer()) // Simulate timer firing
                }
            }
        }
    }

    @objc private func handleCyclicalTimerEvent(timer: Timer) {
        print("Beacon: Cyclical timer fired. Current advertising phase was: \(isCurrentlyInCyclicalAdvertisingPhase).")
        cyclicalAdvertisingTimer?.invalidate()
        cyclicalAdvertisingTimer = nil

        guard isCyclicalModeActive else {
            print("Beacon: Cyclical timer fired but mode is no longer active.")
            return
        }

        isCurrentlyInCyclicalAdvertisingPhase.toggle() // Flip the phase
        print("Beacon: New intended phase is: \(isCurrentlyInCyclicalAdvertisingPhase ? "ADVERTISING" : "PAUSE").")
        initiateNextCyclicalStep()
    }

    private func initiateNextCyclicalStep() {
        guard isCyclicalModeActive else {
            print("Beacon: initiateNextCyclicalStep called but cyclical mode is not active.")
            return
        }

        cyclicalAdvertisingTimer?.invalidate()

        if isCurrentlyInCyclicalAdvertisingPhase { // Should be ON (Advertising)
            print("Beacon: Cycle step: Transitioning to/in ADVERTISING PHASE.")
            // Ensure the iBeacon payload is correctly set up just before advertising
            // This is the most critical change for your iBeacon format issue.
            guard let dataForCycle = originalBeaconDataForCycle else {
                print("Beacon Error: In cycle, but originalBeaconDataForCycle is nil for advertising. Stopping cycle.")
                stopInternal(informListener: true)
                return
            }
            self.iBeaconAdvertisingPayload = generateiBeaconPayload(for: dataForCycle) // Refresh payload
            if self.iBeaconAdvertisingPayload == nil {
                print("Beacon Error: Failed to generate iBeacon payload for advertising phase. Stopping cycle.")
                stopInternal(informListener: true)
                return
            }

            // If already advertising (e.g. BT cycled power while ON), the delegate handles timer.
            // If not advertising (e.g. coming from PAUSE or initial start of cycle), then start.
            if !peripheralManager.isAdvertising {
                 print("Beacon: Cycle step: Starting advertising for ON phase.")
                 attemptToStartAdvertisingNow() // This will use the fresh iBeaconAdvertisingPayload
            } else {
                // This case can happen if BT power cycled while we were in an ON phase.
                // The peripheralManagerDidStartAdvertising should have been called and re-established the timer.
                // If we are here and already advertising, it means the ON phase is current.
                // We should ensure the timer for *its end* is running.
                // This is normally handled by peripheralManagerDidStartAdvertising.
                print("Beacon: Cycle step: Already advertising in ON phase. Timer should be managed by delegate.")
            }

        } else { // Should be OFF (Pause)
            print("Beacon: Cycle step: Transitioning to/in PAUSE PHASE.")
            if peripheralManager.isAdvertising {
                print("Beacon: Cycle step: Stopping advertising for PAUSE phase.")
                peripheralManager.stopAdvertising() // Delegate call will update onAdvertisingStateChanged
            } else {
                // If already not advertising, ensure listener knows we are in a pause (off) state.
                // This might be redundant if delegate already handled it, but good for explicit state.
                self.onAdvertisingStateChanged?(false)
            }

            if let pauseDur = self.pauseDurationForCycle {
                if pauseDur > 0 {
                    print("Beacon: Cycle step: Scheduling end of PAUSE (start of new ON) in \(pauseDur)s.")
                    cyclicalAdvertisingTimer = Timer.scheduledTimer(
                        timeInterval: pauseDur,
                        target: self,
                        selector: #selector(handleCyclicalTimerEvent),
                        userInfo: nil,
                        repeats: false
                    )
                } else { // Pause duration is 0 or less
                    print("Beacon: Cycle step: Pause duration is <= 0. Transitioning to ON phase immediately.")
                    DispatchQueue.main.async { // Avoid deep recursion / allow stack unwind
                        if self.isCyclicalModeActive {
                           // isCurrentlyInCyclicalAdvertisingPhase will be toggled by handleCyclicalTimerEvent
                           self.handleCyclicalTimerEvent(timer: Timer()) // Simulate timer to flip phase and restart
                        }
                    }
                }
            } else {
                print("Beacon Error: Pause duration for cycle is nil. Stopping cycle.")
                stopInternal(informListener: true)
            }
        }
    }
}