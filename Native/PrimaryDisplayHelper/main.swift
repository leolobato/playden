import Foundation
import CoreGraphics
import Dispatch
import Darwin

// stdout is a one-line JSON handshake; stdin EOF releases the display configuration.
// Immersive mode commits a soft disconnect and explicitly restores it before exiting.
func reply(_ value: some Encodable) throws {
    var data = try JSONEncoder().encode(value); data.append(10)
    try FileHandle.standardOutput.write(contentsOf: data)
}

var immersive: ImmersiveDisplayConfiguration?

@MainActor func finish(_ status: Int32) -> Never {
    // Retry transient WindowServer errors before relinquishing the lease.
    for attempt in 0..<3 {
        do { try immersive?.restore(); exit(status) }
        catch {
            fputs("Display restoration failed: \(error.localizedDescription)\n", stderr)
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.1) }
        }
    }
    exit(1)
}

do {
    let parentPID = getppid()
    let arguments = CommandLine.arguments
    guard arguments.count == 3, ["--plan", "--apply", "--immersive"].contains(arguments[1]), UUID(uuidString: arguments[2]) != nil else {
        fputs("Usage: PlaydenPrimaryDisplay --plan|--apply|--immersive DISPLAY_UUID\n", stderr)
        exit(2)
    }
    let layout = try PrimaryDisplayLayout(screens: PrimaryDisplaySystem.screens(), targetUUID: arguments[2])
    if arguments[1] == "--plan" { try reply(layout); exit(0) }

    // A pipe is the lifetime contract. Refuse a terminal or /dev/null so manually invoking
    // --apply without a supervisor cannot briefly change the desktop and immediately exit.
    var info = stat()
    guard fstat(STDIN_FILENO, &info) == 0, info.st_mode & S_IFMT == S_IFIFO else {
        fputs("The display helper requires a supervising process with a stdin pipe.\n", stderr)
        exit(2)
    }
    guard parentPID > 1, getppid() == parentPID else { exit(2) }
    signal(SIGPIPE, SIG_IGN)
    // SIGTERM is used by Process.terminate(); it must follow the same restoration path.
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    termination.setEventHandler { finish(0) }; termination.resume()
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler { finish(0) }; interrupt.resume()
    if arguments[1] == "--immersive" {
        let skyLight = try SkyLightDisplayConfiguration()
        let lease = ImmersiveDisplayConfiguration(targetUUID: arguments[2], online: PrimaryDisplaySystem.screens,
                                                  allDisplays: skyLight.displays, configure: skyLight.configure)
        immersive = lease
        try lease.enforce()
    } else {
        try PrimaryDisplaySystem.applyForHelperLifetime(layout)
    }
    var actual = try PrimaryDisplaySystem.screens()
    for _ in 0..<50 where (actual.first(where: { $0.isMain })?.id != layout.targetID || (immersive != nil && actual.count != 1)) {
        // Let Core Graphics process the configuration before acknowledging readiness.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        actual = try PrimaryDisplaySystem.screens()
    }
    guard let target = actual.first(where: { $0.id == layout.targetID }), target.isMain,
          target.x == 0, target.y == 0, (immersive == nil || actual.count == 1) else { throw PrimaryDisplayError.didNotSwitch }
    try reply(target)

    let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
    input.setEventHandler {
        var byte: UInt8 = 0
        let count = read(STDIN_FILENO, &byte, 1)
        if count == 0 || (count < 0 && errno != EINTR && errno != EAGAIN) { finish(0) }
    }
    input.resume()
    // Also follow the owner process, independently of any inadvertently inherited pipe fd.
    let owner = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit, queue: .main)
    owner.setEventHandler { finish(0) }
    owner.resume()
    if getppid() != parentPID { finish(0) }
    let topology = DispatchSource.makeTimerSource(queue: .main)
    topology.schedule(deadline: .now() + 1, repeating: 1)
    topology.setEventHandler {
        do { try immersive?.enforce() }
        catch { finish(1) } // Target unplugged: reconnect the other monitors immediately.
    }
    topology.resume()
    dispatchMain()
} catch {
    try? reply(PrimaryDisplayHelperFailure(error: error.localizedDescription))
    fputs("\(error.localizedDescription)\n", stderr)
    finish(1)
}
