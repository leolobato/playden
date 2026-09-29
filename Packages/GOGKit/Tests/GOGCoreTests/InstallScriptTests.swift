import XCTest
@testable import GOGCore

final class InstallScriptTests: XCTestCase {
    /// The shape of Beneath a Steel Sky's and The Elder Scrolls: Arena's scripts.
    let script = #"""
    {"actions":[
     {"install":{"action":"supportData","arguments":{"saveGameData":true,"target":"{app}/saves","type":"folder"}},"languages":["*"],"name":"createFolder"},
     {"install":{"action":"setIni","arguments":{"filename":"{app}\\beneath.ini","keyName":"path","keyType":"string","keyValue":"{app}","section":"beneath","utf8":false}},"languages":["*"],"name":"ini1"},
     {"install":{"action":"setIni","arguments":{"filename":"{app}\\beneath.ini","keyName":"savepath","keyType":"string","keyValue":"{app}\\saves","section":"beneath","utf8":false}},"languages":["*"],"name":"ini2"},
     {"install":{"action":"setIni","arguments":{"filename":"{app}\\beneath.ini","keyName":"language","keyType":"string","keyValue":"de","section":"beneath","utf8":false}},"languages":["de-DE"],"name":"inilang"},
     {"install":{"action":"supportData","arguments":{"overwrite":false,"source":"{supportDir}/save","target":"{app}","type":"folder"}},"languages":["*"],"name":"copyConfig"},
     {"install":{"action":"setRegistry","arguments":{"root":"HKEY_LOCAL_MACHINE","subkey":"Software\\GOG.com\\Games\\{productID}"}},"languages":["*"],"name":"reg"},
     {"install":{"action":"supportData","arguments":{"source":"{supportDir}/../../x","target":"{app}","type":"folder"}},"languages":["*"],"name":"escape"}
    ]}
    """#

    var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("gog-isi-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func context() -> GOGInstallScript.Context {
        .init(gameRoot: root.appendingPathComponent("game"), supportRoot: root.appendingPathComponent("game/.playden-gog/support/7"),
              productID: "7", language: "en-US", windowsAppPath: #"Z:\Games\BASS"#)
    }

    func testStepsFollowLanguageAndSkipRegistryAndEscapes() throws {
        let steps = try GOGInstallScript.parse(Data(script.utf8)).steps(context())
        let game = root.appendingPathComponent("game")
        XCTAssertEqual(steps, [
            .createFolder(game.appendingPathComponent("saves")),
            .setINI(file: game.appendingPathComponent("beneath.ini"), section: "beneath", key: "path", value: #"Z:\Games\BASS"#, utf8: false),
            .setINI(file: game.appendingPathComponent("beneath.ini"), section: "beneath", key: "savepath", value: #"Z:\Games\BASS\saves"#, utf8: false),
            .copyFolder(from: game.appendingPathComponent(".playden-gog/support/7/save"), to: game, overwrite: false),
        ])
        XCTAssertEqual(try GOGInstallScript.parse(Data(script.utf8)).steps(context(), skipCopies: true).count, 3)
    }

    func testRunWritesTheINIAndCopiesWithoutOverwriting() throws {
        let game = root.appendingPathComponent("game"), save = game.appendingPathComponent(".playden-gog/support/7/save")
        try FileManager.default.createDirectory(at: save.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: save.appendingPathComponent("SAVE.DAT"))
        try Data("x".utf8).write(to: save.appendingPathComponent("sub/a.cfg"))
        try Data("mine".utf8).write(to: game.appendingPathComponent("SAVE.DAT"))
        try Data("[scummvm]\r\nfullscreen=true\r\n\r\n[beneath]\r\ngameid=sky\r\nPATH=old\r\n".utf8).write(to: game.appendingPathComponent("beneath.ini"))
        try GOGInstallScript.parse(Data(script.utf8)).run(context())
        XCTAssertEqual(try String(contentsOf: game.appendingPathComponent("beneath.ini"), encoding: .isoLatin1),
                       "[scummvm]\r\nfullscreen=true\r\n\r\n[beneath]\r\ngameid=sky\r\npath=Z:\\Games\\BASS\r\nsavepath=Z:\\Games\\BASS\\saves\r\n")
        XCTAssertEqual(try String(contentsOf: game.appendingPathComponent("SAVE.DAT"), encoding: .utf8), "mine", "overwrite false keeps the player's file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: game.appendingPathComponent("sub/a.cfg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: game.appendingPathComponent("saves").path))
    }

    func testSettingINIAddsSectionsAndKeys() {
        XCTAssertEqual(GOGInstallScript.settingINI("", section: "s", key: "k", value: "v"), "[s]\r\nk=v\r\n")
        XCTAssertEqual(GOGInstallScript.settingINI("[a]\nx=1\n", section: "s", key: "k", value: "v"), "[a]\nx=1\n\n[s]\nk=v\n")
        XCTAssertEqual(GOGInstallScript.settingINI("[s]\nx=1\n\n[t]\ny=2\n", section: "S", key: "k", value: "v"), "[s]\nx=1\nk=v\n\n[t]\ny=2\n")
    }
}
