import Foundation
import CoreGraphics
import Dispatch
import Darwin

// stdout is a one-line JSON handshake; stdin EOF releases the display configuration.
// No Wine APIs, runtime injection, Accessibility access, or permanent configuration writes.
func reply(_ value: some Encodable) throws {
    var data = try JSONEncoder().encode(value); data.append(10)
    try FileHandle.standardOutput.write(contentsOf: data)
}

do {
    let parentPID = getppid()
    let arguments = CommandLine.arguments
    guard arguments.count == 3, ["--plan", "--apply"].contains(arguments[1]), UUID(uuidString: arguments[2]) != nil else {
        fputs("Usage: PlaydenPrimaryDisplay --plan|--apply DISPLAY_UUID\n", stderr)
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
    try PrimaryDisplaySystem.applyForHelperLifetime(layout)
    var actual = try PrimaryDisplaySystem.screens()
    for _ in 0..<50 where actual.first(where: { $0.isMain })?.id != layout.targetID {
        // Let Core Graphics process the configuration before acknowledging readiness.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        actual = try PrimaryDisplaySystem.screens()
    }
    guard let target = actual.first(where: { $0.id == layout.targetID }), target.isMain,
          target.x == 0, target.y == 0 else { throw PrimaryDisplayError.didNotSwitch }
    try reply(target)

    let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
    input.setEventHandler {
        var byte: UInt8 = 0
        let count = read(STDIN_FILENO, &byte, 1)
        if count == 0 || (count < 0 && errno != EINTR && errno != EAGAIN) { exit(0) }
    }
    input.resume()
    // Also follow the owner process, independently of any inadvertently inherited pipe fd.
    let owner = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit, queue: .main)
    owner.setEventHandler { exit(0) }
    owner.resume()
    if getppid() != parentPID { exit(0) }
    dispatchMain()
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1) // .forAppOnly is reverted by macOS even on errors after configuration.
}
