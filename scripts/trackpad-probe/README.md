# Trackpad phase-one probe

Independent macOS 13+ development executable; not installed as a service and not
part of the App/Helper capture chain. Dynamically loads private MultitouchSupport.
Unavailable symbols/devices/start failures exit with an explicit error. Private
ABI compatibility is a real-device gate, not a supported Apple API guarantee.

Build with Xcode's swiftc targeting arm64-apple-macos13.0 (or the corresponding
Intel target). Run `TrackpadProbe 30`; duration is bounded to 5–60 seconds.
A zero-frame result does **not** pass capture acceptance.

Output contains aggregate diagnostics only. No contact identifiers, coordinates,
paths or event order are persisted. One previous sample per live contact is kept
in memory to check continuity and derive distance in normalized surface units.
Motion is not connected across disappearance, release, or gaps over 250ms. These
are diagnostic breaks, not the final recording segmentation specification.

Check separate runs for idle, single/multiple fingers, stationary contact, quick
motion, light touch versus mechanical/Force click, background application use,
sleep/resume and external device disconnect. This version uses the default device
only; it does not yet validate device enumeration or reconnection. Callback
states represent contact, **not** mechanical button state. Pressure and area
fields are uncalibrated ABI observations, not force or physical area measurements.

CPU and maximum RSS describe this short-lived probe only. Estimated bytes/minute
are uncompressed ABI sample volume, not encrypted production storage volume.
Wakeups, energy, production disk writes and reliable physical-click attribution
remain unmeasured. No synthetic input can replace actual touch acceptance.

Do not add persistent recording or claim complete Replay until the phase-one
real-device matrix passes. See THIRD_PARTY_NOTICES.md for ABI attribution.

## Isolated encrypted replay regression

Compile `KeytideHelper/TrackpadRecording.swift` together with
`scripts/trackpad-probe/replay-tests/main.swift` using the macOS SDK and run the
result. It creates and deletes its own temporary encrypted fixtures with an
in-memory key. It does not open a device, production App, Keychain, or user data.
The regression checks 512,000 frames, bounded delivery, order, cancellation,
corruption and day authentication. Timings exclude drawing and are not a GUI
10-second guarantee.
