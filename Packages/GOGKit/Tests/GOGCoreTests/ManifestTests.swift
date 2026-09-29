import XCTest
@testable import GOGCore

func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

final class ManifestTests: XCTestCase {
    func testBuildsListMixesGenerationsAndPicksTheDefaultBranch() throws {
        struct Response: Decodable { var items: [GOGBuild] }
        let builds = try JSONDecoder().decode(Response.self, from: try fixture("builds-mixed.json")).items
        XCTAssertEqual(Set(builds.map(\.generation)), [1, 2])
        let chosen = try XCTUnwrap(GOGResolver.defaultBuild(builds))
        XCTAssertEqual(chosen.generation, 2)
        XCTAssertNotNil(builds.first { $0.generation == 1 }?.legacy_build_id)
        let ordered = GOGResolver.ordered(try XCTUnwrap(chosen.urls))
        XCTAssertEqual(ordered.first?.endpoint_name, "fastly")
        XCTAssertEqual(ordered.last?.fallback_only, true)
    }

    func testDefaultBuildSkipsNamedBranches() throws {
        let json = #"[{"build_id":"2","product_id":"1","os":"windows","branch":"beta","generation":2},{"build_id":"1","product_id":"1","os":"windows","branch":null,"generation":2}]"#
        let builds = try JSONDecoder().decode([GOGBuild].self, from: Data(json.utf8))
        XCTAssertEqual(GOGResolver.defaultBuild(builds)?.build_id, "1")
    }

    func testV2BuildManifestAndSelection() throws {
        let meta = try JSONDecoder().decode(GOGBuildManifestV2.self, from: try fixture("meta-v2.json"))
        XCTAssertEqual(meta.baseProductId.value, "1441974651")
        XCTAssertEqual(meta.dependencies, ["MSVC2010", "MSVC2013", "MSVC2017"])
        let listed = meta.products?.map(\.productId.value) ?? []
        let products = GOGDepotSelection.products(base: "1441974651", listed: listed, owned: ["1619024184", "999"])
        XCTAssertEqual(products, ["1441974651", "1619024184"])
        let depots = GOGDepotSelection.depots(meta, products: products, language: "english")
        XCTAssertEqual(Set(depots.map(\.productId.value)), ["1441974651", "1619024184"])
        XCTAssertTrue(depots.allSatisfy { $0.productId.value == "1441974651" || $0.isGogDepot == true })
        // English-only depots don't cover German; resolve falls back to English before selecting.
        XCTAssertTrue(GOGDepotSelection.depots(meta, products: ["1441974651"], language: "german").isEmpty)
        XCTAssertEqual(GOGDepotSelection.language("german", available: meta.depots.map(\.languages)), "english")
    }

    func testV2DepotManifest() throws {
        let manifest = try JSONDecoder().decode(GOGDepotManifestV2.self, from: try fixture("depot-v2.json"))
        let files = try GOGDepotSelection.files(manifest, product: "1619024184")
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].chunks?.count, 1)
        XCTAssertEqual(files[0].size, 157)
        XCTAssertNotNil(files[0].md5, "a one-chunk file uses the chunk MD5 as its whole-file hash")
    }

    func testV2ItemsNormalizePathsAndFlags() throws {
        let json = #"{"version":2,"depot":{"items":[{"type":"DepotFile","path":"Game.app\\Contents\\MacOS\\Game","flags":["executable"],"chunks":[{"md5":"a","compressedMd5":"b","size":"10","compressedSize":4}]},{"type":"DepotFile","path":"\\cfg.ini","flags":["support"],"chunks":[]},{"type":"DepotDirectory","path":"Saves"},{"type":"DepotLink","path":"Game.app\\Current","target":"Versions\\A"}]}}"#
        let files = try GOGDepotSelection.files(try JSONDecoder().decode(GOGDepotManifestV2.self, from: Data(json.utf8)), product: "7")
        XCTAssertEqual(files.map(\.path), ["Game.app/Contents/MacOS/Game", ".playden-gog/support/7/cfg.ini", "Saves", "Game.app/Current"])
        XCTAssertEqual(files.map(\.kind), [.file, .file, .directory, .link])
        XCTAssertTrue(files[0].executable)
        XCTAssertEqual(files[0].size, 10)
        XCTAssertEqual(files[3].target, "Versions/A")
        XCTAssertThrowsError(try GOGPaths.normalize("a/../../b"))
    }

    func testV1RepositoryAndDepot() throws {
        let repository = try JSONDecoder().decode(GOGRepositoryV1.self, from: try fixture("repository-v1.json"))
        XCTAssertEqual(repository.product.rootGameID.value, "1425039730")
        XCTAssertEqual(repository.product.depots.compactMap(\.redist), ["MSVC2008", "dotNet35", "DirectX", "language_setup"])
        let depots = GOGDepotSelection.depots(repository, products: ["1425039730"], language: "english")
        XCTAssertEqual(depots.count, 2, "Neutral and English")
        XCTAssertEqual(GOGDepotSelection.depots(repository, products: ["1425039730"], language: "german").count, 1)
        let files = try GOGDepotSelection.files(try JSONDecoder().decode(GOGDepotManifestV1.self, from: try fixture("depot-v1.json")), product: "1425039730")
        XCTAssertEqual(files.first?.path, ".playden-gog/support/1425039730/1425039730/galaxy_monkey_island2_se_2.0.0.10.exe")
        XCTAssertEqual(files.first?.offset, 0)
        XCTAssertEqual(files.first?.size, 1_280_640)
        XCTAssertEqual(files.first?.md5, "4bc0f38e5298ab0ac22e913c52568064")
    }

    func testV1LinksDirectoriesAndExecutables() throws {
        let json = #"{"version":1,"depot":{"files":[{"path":"/Contents/MacOS/GOGLauncher","offset":10,"size":5,"hash":"h","url":"42/main.bin","executable":true},{"path":"/Contents/Frameworks/SDL2.framework/SDL2","target":"Versions/Current/SDL2","symlinkType":"file"},{"path":"/Contents/Resources","directory":true}]}}"#
        let files = try GOGDepotSelection.files(try JSONDecoder().decode(GOGDepotManifestV1.self, from: Data(json.utf8)), product: "42")
        XCTAssertEqual(files.map(\.kind), [.file, .link, .directory])
        XCTAssertTrue(files[0].executable)
        XCTAssertEqual(files[0].product, "42")
        XCTAssertEqual(files[1].target, "Versions/Current/SDL2")
    }

    func testDependencies() throws {
        let repository = try JSONDecoder().decode(GOGDependencyRepository.self, from: try fixture("dependencies.json"))
        let dosbox = try XCTUnwrap(repository.depots.first { $0.dependencyId == "DOSBox074_2CS" })
        XCTAssertTrue(dosbox.isGameFolderDependency)
        let directX = try XCTUnwrap(repository.depots.first { $0.dependencyId == "DirectX" })
        XCTAssertFalse(directX.isGameFolderDependency)
        let depot = try JSONDecoder().decode(GOGDepotManifestV2.self, from: try fixture("dependency-depot.json"))
        let files = try GOGDepotSelection.files(depot, product: GOGFile.dependencyStore)
        XCTAssertTrue(files.contains { $0.path == "DOSBOX/DOSBox.exe" })
    }

    func testChunkFixtureDecodes() throws {
        let raw = try fixture("dependency-chunk.bin")
        let chunk = GOGChunk(md5: "6edd4ea41d69ba42d4724319f3fe0dc9", compressedMd5: "3f296756b344d71d92e22377b325c042", size: 3833, compressedSize: 1679)
        XCTAssertEqual(GOGCodec.md5(raw), chunk.compressedMd5)
        let data = try GOGCodec.inflateZlib(raw)
        XCTAssertEqual(GOGCodec.md5(data), chunk.md5)
        XCTAssertEqual(Int64(data.count), chunk.size)
    }

    func testInfoFile() throws {
        let json = "\u{FEFF}" + #"{"gameId":"2116968103","playTasks":[{"category":"launcher","isPrimary":true,"path":"VirtuaVerse.exe","type":"FileTask"},{"category":"game","isHidden":true,"path":"VirtuaVerse/VirtuaVerse.exe","type":"FileTask"},{"category":"tool","path":"Setup.exe","name":"Setup","type":"FileTask"},{"category":"document","path":"Manual.pdf","type":"FileTask"},{"link":"http://www.gog.com/support","type":"URLTask"}]}"#
        let info = try GOGInfoFile.parse(Data(json.utf8))
        XCTAssertEqual(info.gameId, "2116968103")
        XCTAssertEqual(info.primaryTask?.path, "VirtuaVerse.exe")
        XCTAssertEqual(info.optionTasks.map(\.path), ["Setup.exe"])
        let noPrimary = try GOGInfoFile.parse(Data(#"{"playTasks":[{"link":"x","type":"URLTask"},{"path":"a.exe","type":"FileTask"}]}"#.utf8))
        XCTAssertEqual(noPrimary.primaryTask?.path, "a.exe")
    }

    func testLanguages() {
        XCTAssertTrue(GOGLanguage.depot(["en-US"], covers: "english"))
        XCTAssertTrue(GOGLanguage.depot(["English"], covers: "english"))
        XCTAssertTrue(GOGLanguage.depot(["de-DE"], covers: "german"))
        XCTAssertFalse(GOGLanguage.depot(["de-DE"], covers: "english"))
        XCTAssertTrue(GOGLanguage.isNeutral(["*"]))
        XCTAssertTrue(GOGLanguage.isNeutral(["Neutral"]))
        XCTAssertEqual(GOGDepotSelection.language("german", available: [["en-US"]]), "english")
        XCTAssertEqual(GOGDepotSelection.language("german", available: [["en-US"], ["de-DE"]]), "german")
    }

    func testBitnessPrefers64() throws {
        let json = #"{"baseProductId":"1","installDirectory":"G","depots":[{"productId":"1","languages":["*"],"manifest":"a","osBitness":["32"]},{"productId":"1","languages":["*"],"manifest":"b","osBitness":["64"]},{"productId":"1","languages":["*"],"manifest":"c"},{"productId":"2","languages":["*"],"manifest":"d","osBitness":["32"]}]}"#
        let meta = try JSONDecoder().decode(GOGBuildManifestV2.self, from: Data(json.utf8))
        XCTAssertEqual(GOGDepotSelection.depots(meta, products: ["1", "2"], language: "english").map(\.manifest), ["b", "c", "d"])
    }

    func testMergeLetsLaterDepotsWin() {
        let base = GOGFile(path: "Data/a.pak", size: 1, product: "1"), dlc = GOGFile(path: "data/A.pak", size: 2, product: "2")
        let merged = GOGDepotSelection.merge([[base, GOGFile(path: "b", product: "1")], [dlc]])
        XCTAssertEqual(merged.map(\.size), [2, 0])
        XCTAssertEqual(merged.first?.product, "2")
    }

    func testInfoFileLocation() {
        let manifest = GOGInstallManifest(generation: 2, productID: "5", buildID: "b", platform: "osx", versionName: nil, installDirectory: "G",
            language: "en-US", products: ["5"], dependencies: [], files: [
                GOGFile(path: "Contents/Resources/goggame-5.info", product: "5"), GOGFile(path: "Contents/Resources/goggame-6.info", product: "6"),
            ])
        XCTAssertEqual(manifest.infoFile?.path, "Contents/Resources/goggame-5.info")
        let v1 = GOGInstallManifest(generation: 1, productID: "5", buildID: "b", platform: "osx", versionName: nil, installDirectory: "G",
            language: "en-US", products: ["5"], dependencies: [], files: [GOGFile(path: "Contents/Resources/.goggame-5.info", product: "5")])
        XCTAssertEqual(v1.infoFile?.path, "Contents/Resources/.goggame-5.info")
    }
}
