import Foundation
import Domain

public struct RuntimeInfo: Equatable, Sendable {
    public let version: String?
    public let templateVersion: String
    public let templateReady: Bool
    public let failure: OperationFailure?
    public init(version: String?, templateVersion: String, templateReady: Bool, failure: OperationFailure? = nil) {
        self.version = version; self.templateVersion = templateVersion; self.templateReady = templateReady; self.failure = failure
    }
}
public enum TemplateStage: String, Sendable { case checking, creating, configuring, validating, ready }
public protocol BottleManaging: Sendable {
    func inspect() async -> RuntimeInfo
    func prepareTemplate(onProgress: @escaping @Sendable (TemplateStage) -> Void) async throws -> RuntimeInfo
}

/// Owns only the pinned launcher template. Existing user bottles are never adopted or modified.
public actor CrossOverRuntime: BottleManaging {
    public static let templateVersion = "1"
    private let application: URL
    private let bottles: URL
    private let stateDirectory: URL
    private let templateName: String
    private let commands: any CommandExecuting
    private var preparing = false
    private let files = FileManager.default
    public init(application: URL = URL(fileURLWithPath: "/Applications/CrossOver.app"),
                bottles: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CrossOver/Bottles"),
                stateDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Big Screen/runtime"),
                templateName: String = "gn-template-1", commands: any CommandExecuting = CommandExecutor()) {
        self.application = application; self.bottles = bottles; self.stateDirectory = stateDirectory
        self.templateName = templateName; self.commands = commands
    }
    private var template: URL { bottles.appendingPathComponent(templateName, isDirectory: true) }
    private var receiptURL: URL { stateDirectory.appendingPathComponent(templateName + ".json") }
    private var failureURL: URL { stateDirectory.appendingPathComponent(templateName + ".failure.json") }
    private func tool(_ name: String) -> URL { application.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/" + name) }
    public func inspect() -> RuntimeInfo {
        do {
            let version = try checkRuntime()
            var ready = false
            if let receipt = try loadReceipt(), receipt.ready {
                try verifyOwnership(receipt.owner); try verifyConfiguration(); ready = true
            }
            let failure = (try? Data(contentsOf: failureURL)).flatMap { try? JSONDecoder().decode(OperationFailure.self, from: $0) }
            return RuntimeInfo(version: version, templateVersion: Self.templateVersion, templateReady: ready, failure: failure)
        } catch {
            return RuntimeInfo(version: nil, templateVersion: Self.templateVersion, templateReady: false,
                               failure: failure(error, stage: "Check runtime"))
        }
    }
    public func prepareTemplate(onProgress: @escaping @Sendable (TemplateStage) -> Void = { _ in }) async throws -> RuntimeInfo {
        guard !preparing else { throw issue("Prepare template", "Game setup is already running.") }
        preparing = true; defer { preparing = false }
        var stage = "Check runtime"
        do {
            try Task.checkCancellation(); onProgress(.checking)
            let version = try checkRuntime()
            try files.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            var receipt: TemplateReceipt
            if let saved = try loadReceipt() { receipt = saved }
            else {
                guard !exists(template) else { throw issue("Create template", "A bottle with the setup name already exists and does not belong to Big Screen.") }
                receipt = TemplateReceipt(owner: BottleOwner(name: templateName, version: Self.templateVersion, token: UUID()), ready: false)
                try write(receipt, to: receiptURL)
            }
            if !exists(template) {
                receipt.ready = false; try write(receipt, to: receiptURL)
                stage = "Create template"; onProgress(.creating)
                let result = try await commands.run(executable: tool("cxbottle"), arguments: ["--bottle", templateName,
                    "--create", "--template", "win10_64", "--description", receipt.owner.description,
                    "--param", "EnvironmentVariables:WINEMSYNC=1", "--param", "EnvironmentVariables:CX_GRAPHICS_BACKEND=d3dmetal"], timeout: 90)
                // A durable reservation and the command's own description identify partial creation.
                if exists(template) { try claimCreatedBottle(receipt.owner) }
                try requireSuccess(result, stage: stage)
            }
            stage = "Configure template"; onProgress(.configuring)
            if !exists(template.appendingPathComponent(".bigscreen-owner.json")) { try claimCreatedBottle(receipt.owner) }
            try verifyOwnership(receipt.owner); try verifyConfiguration()
            receipt.ready = false; try write(receipt, to: receiptURL)
            stage = "Validate template"; onProgress(.validating)
            // Exercises Wine startup and any license/runtime errors before the first install.
            let result = try await commands.run(executable: tool("cxstart"), arguments: ["--bottle", templateName,
                "--no-gui", "--wait-children", "cmd.exe", "/c", "echo BIGSCREEN_TEMPLATE_READY"], timeout: 45)
            try requireSuccess(result, stage: stage)
            guard result.output.contains("BIGSCREEN_TEMPLATE_READY") else { throw issue(stage, "The game runtime did not finish its startup check.", output: result.output) }
            try Task.checkCancellation()
            receipt.ready = true; try write(receipt, to: receiptURL)
            if exists(failureURL) { try files.removeItem(at: failureURL) }
            onProgress(.ready)
            return RuntimeInfo(version: version, templateVersion: Self.templateVersion, templateReady: true)
        } catch {
            let problem = failure(error, stage: stage)
            try? files.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            try? write(problem, to: failureURL)
            throw problem
        }
    }
    private func checkRuntime() throws -> String {
        guard templateName.range(of: #"^gn-[A-Za-z0-9-]+$"#, options: .regularExpression) != nil else { throw issue("Check runtime", "The template name is invalid.") }
        guard files.isExecutableFile(atPath: tool("cxbottle").path), files.isExecutableFile(atPath: tool("cxstart").path) else {
            throw issue("Check runtime", "Install CrossOver in Applications, then try again.")
        }
        let info = try Data(contentsOf: application.appendingPathComponent("Contents/Info.plist"))
        let properties = try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any]
        guard let version = properties?["CFBundleShortVersionString"] as? String,
              let major = version.split(separator: ".").first.flatMap({ Int($0) }), major >= 26 else {
            throw issue("Check runtime", "Big Screen needs CrossOver 26 or newer.")
        }
        return version
    }
    private func exists(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isSymbolicLinkKey])) != nil }
    private func safeTemplate() throws {
        let values = try template.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true,
              template.resolvingSymlinksInPath().deletingLastPathComponent() == bottles.resolvingSymlinksInPath() else {
            throw issue("Check template", "The game setup folder has moved or is not owned by Big Screen.")
        }
    }
    private func configuration() throws -> String {
        try safeTemplate()
        let path = template.appendingPathComponent("cxbottle.conf")
        guard try path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw issue("Check template", "The game setup configuration points outside its folder.") }
        return try String(contentsOf: path, encoding: .utf8)
    }
    private func claimCreatedBottle(_ owner: BottleOwner) throws {
        let config = try configuration()
        guard config.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).contains("\"Description\" = \"\(owner.description)\"") else {
            throw issue("Create template", "A partial setup folder could not be identified safely. Its files have been kept.")
        }
        let marker = template.appendingPathComponent(".bigscreen-owner.json")
        if exists(marker) { try verifyOwnership(owner) }
        else { try write(owner, to: marker) }
    }
    private func verifyOwnership(_ owner: BottleOwner) throws {
        try safeTemplate()
        let marker = template.appendingPathComponent(".bigscreen-owner.json")
        guard try marker.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              try JSONDecoder().decode(BottleOwner.self, from: Data(contentsOf: marker)) == owner else {
            throw issue("Check template", "This game setup folder does not belong to Big Screen.")
        }
    }
    private func verifyConfiguration() throws {
        let text = try configuration()
        var section = "", values: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line; continue }
            guard section == "[EnvironmentVariables]", line.hasPrefix("\""), let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        }
        guard values["\"WINEMSYNC\""] == "\"1\"", values["\"CX_GRAPHICS_BACKEND\""] == "\"d3dmetal\"" else {
            throw issue("Configure template", "The game runtime settings could not be verified.")
        }
    }
    private func loadReceipt() throws -> TemplateReceipt? {
        guard exists(receiptURL) else { return nil }
        let receipt = try JSONDecoder().decode(TemplateReceipt.self, from: Data(contentsOf: receiptURL))
        guard receipt.owner.name == templateName, receipt.owner.version == Self.templateVersion else { throw issue("Check template", "The saved game setup version does not match.") }
        return receipt
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws { try JSONEncoder().encode(value).write(to: url, options: .atomic) }
    private func requireSuccess(_ result: CommandResult, stage: String) throws {
        if result.cancelled { throw issue(stage, "Game setup was stopped. You can retry when you’re ready.", output: result.output) }
        if result.timedOut { throw issue(stage, "Game setup took too long. Try again or view the details.", output: result.output) }
        guard result.exitCode == 0 else {
            let license = result.output.range(of: #"(?i)(license|licence|trial).*(expired|invalid|required)|not (licensed|registered)"#, options: .regularExpression) != nil
            throw issue(stage, license ? "Open CrossOver to activate your license, then try again." : "Game setup could not finish this step.", output: result.output)
        }
        try Task.checkCancellation()
    }
    private func issue(_ stage: String, _ reason: String, output: String = "") -> OperationFailure { OperationFailure(stage: stage, reason: reason, output: output) }
    private func failure(_ error: Error, stage: String) -> OperationFailure {
        if let error = error as? OperationFailure { return error }
        if error is CancellationError { return issue(stage, "Game setup was stopped. You can retry when you’re ready.") }
        return issue(stage, "Game setup could not finish this step.", output: error.localizedDescription)
    }
}
private struct BottleOwner: Codable, Equatable {
    var name: String
    var version: String
    var token: UUID
    var description: String { "Big Screen managed template \(token.uuidString)" }
}
private struct TemplateReceipt: Codable { var owner: BottleOwner; var ready: Bool }
