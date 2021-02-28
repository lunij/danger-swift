import Foundation
import Logger
import ShellRunner

public struct ScriptManager {
    public struct Config {
        let dependencyPrefix: String
        let dependencyFile: String
        let majorVersionPrefix: String

        public init(prefix: String = "package: ",
                    file: String = "Dangerplugins",
                    major: String = "~> ") {
            dependencyPrefix = prefix
            dependencyFile = file
            majorVersionPrefix = major
        }
    }

    enum Errors: Error {
        case failedToCreatePackageFile(String)
        case invalidInlineDependencyURL(String)
        case failedToAddDependencyScript(String)
        case scriptNotFound(String)
    }

    private let config = Config()
    private let packageManager: PackageManager
    private let folder: String
    private let cacheFolder: String
    private let temporaryFolder: String
    private let logger: Logger
    private let inlineDependenciesFinder: InlineDependenciesFinder

    public init(folder: String,
                packageManager: PackageManager,
                logger: Logger) throws {
        self.folder = folder
        self.logger = logger
        cacheFolder = try folder.createSubfolderIfNeeded(withName: "Cache")
        temporaryFolder = try folder.createSubfolderIfNeeded(withName: "Temp")
        inlineDependenciesFinder = InlineDependenciesFinder(config: config)
        self.packageManager = packageManager
    }

    public func script(atPath path: String) throws -> Script {
        let path = path.asScriptPath()
        if FileManager.default.fileExists(atPath: path) {
            return try script(fromPath: path)
        } else {
            throw Errors.scriptNotFound(path)
        }
    }

    private func script(fromPath path: String) throws -> Script {
        let identifier = scriptIdentifier(fromPath: path)
        let folder = try createFolderIfNeededForScript(withIdentifier: identifier, filePath: path)
        let script = Script(name: path.nameExcludingExtension, folder: folder, logger: logger)

        let packages = try inlineDependenciesFinder.resolveInlineDependencies(fromPath: path)
        try packageManager.addPackagesIfNeeded(from: packages)

        do {
            try FileManager.default.createFile(atPath: folder.appendingPath("Package.swift"),
                                               contents: packageManager.makePackageDescription(for: script),
                                               attributes: [:])
        } catch {
            throw Errors.failedToCreatePackageFile(folder)
        }

        return script
    }

    private func scriptIdentifier(fromPath path: String) -> String {
        let pathExcludingExtension = path.components(separatedBy: ".swift").first
        return pathExcludingExtension?.replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-") ?? "Dangerfile.swift"
    }

    private func createFolderIfNeededForScript(withIdentifier identifier: String, filePath: String) throws -> String {
        let scriptFolder = try cacheFolder.createSubfolderIfNeeded(withName: identifier)
        try packageManager.symlinkPackages(to: scriptFolder)

        if !FileManager.default.fileExists(atPath: scriptFolder.appendingPath("OriginalFile")) {
            try scriptFolder.createSymlink(to: filePath, at: "OriginalFile")
        }

        let sourcesFolder = try scriptFolder.createSubfolderIfNeeded(withName: "Sources")
        try FileManager.default.removeItem(atPath: sourcesFolder)

        let moduleFolder = try sourcesFolder.createSubfolder(withName: filePath.nameExcludingExtension)

        FileManager.default.createFile(atPath: moduleFolder.appendingPath("main.swift"),
                                       contents: Data(try String(contentsOfFile: filePath).utf8),
                                       attributes: [:])

        return scriptFolder
    }
}

public final class Script {
    enum Errors: Error {
        case watchingFailed(String)
    }

    public let name: String
    public let folder: String

    private var copyLoopDispatchQueue: DispatchQueue?
    private var localPath: String { "Sources/\(name)/main.swift" }
    private var logger: Logger

    init(name: String, folder: String, logger: Logger) {
        self.name = name
        self.folder = folder
        self.logger = logger
    }

    public func build(withArguments arguments: [String] = []) throws {
        let shell = ShellRunner()
        try executeSwiftCommand("build --package-path \(folder)", arguments: arguments, shell: shell)
    }

    @discardableResult
    public func setupForEdit(importedFiles: [String], configPath: String) throws -> String {
        try importedFiles.forEach {
            if !FileManager.default.fileExists(atPath: $0) {
                _ = FileManager.default.createFile(atPath: $0, contents: nil, attributes: nil)
            }
            try FileManager.default.copyItem(atPath: $0, toPath: sourcesImportPath(forImportPath: $0))
        }

        try generateXCodeProjWithConfig(configPath: configPath)

        return editingPath()
    }

    private func editingPath() -> String {
        folder.appendingPath(name + ".xcodeproj")
    }

    private func generateXCodeProjWithConfig(configPath: String) throws {
        try executeSwiftCommand("package generate-xcodeproj --xcconfig-overrides \(configPath)",
                                onFolder: folder,
                                shell: ShellRunner())
    }

    private func sourcesImportPath(forImportPath importPath: String) -> String {
        folder
            .appendingPath("Sources")
            .appendingPath(name)
            .appendingPath(importPath.fileName)
    }

    public func watch(importedFiles: [String]) throws {
        let fullPathImports = importedFiles.map { $0.fullPath }
        try watch(imports: fullPathImports)
        try? copyImports(fullPathImports)
    }

    public func watch(imports: [String]) throws {
        do {
            let path = editingPath()

            try ShellRunner().run("open \"\(path)\"")

            logger.logInfo("\nℹ️  Danger will keep running, " +
                "in order to commit any changes you make in Xcode back to the original script file")
            logger.logInfo("   Press the return key once you're done")

            startCopyLoop(imports: imports)
            _ = FileHandle.standardInput.availableData
            try copyChangesToSymlinkedFile()
        } catch {
            throw Errors.watchingFailed(name)
        }
    }

    private func startCopyLoop(imports: [String]) {
        let dispatchQueue: DispatchQueue

        if let existingQueue = copyLoopDispatchQueue {
            dispatchQueue = existingQueue
        } else {
            let newQueue = DispatchQueue(label: "com.danger.fileCopyLoop")
            copyLoopDispatchQueue = newQueue
            dispatchQueue = newQueue
        }

        dispatchQueue.asyncAfter(deadline: .now() + .seconds(3)) { [weak self] in
            try? self?.copyChangesToSymlinkedFile()
            try? self?.copyImports(imports)
            self?.startCopyLoop(imports: imports)
        }
    }

    private func copyChangesToSymlinkedFile() throws {
        let script = try expandSymlink()

        let data = try Data(contentsOf: URL(fileURLWithPath: folder.appendingPath(localPath)))
        try data.write(to: URL(fileURLWithPath: script))
    }

    private func expandSymlink() throws -> String {
        try ShellRunner().run("readlink \(folder.appendingPath("OriginalFile"))")
    }

    private func copyImports(_ imports: [String]) throws {
        try imports.forEach { importPath in
            try Data(contentsOf:
                URL(fileURLWithPath: sourcesImportPath(forImportPath: importPath)))
                .write(to: URL(fileURLWithPath: importPath))
        }
    }
}

@discardableResult
func executeSwiftCommand(_ command: String,
                         onFolder folder: String? = nil,
                         arguments: [String] = [],
                         shell: ShellRunnerProtocol = ShellRunner()) throws -> String {
    func resolveSwiftPath() -> String {
        #if os(Linux)
            return "swift"
        #else
            return "/usr/bin/env xcrun --sdk macosx swift"
        #endif
    }

    let swiftPath = resolveSwiftPath()
    let command = folder.map { "cd \($0) && \(swiftPath) \(command)" } ?? "\(swiftPath) \(command)"

    return try shell.run(command, arguments: arguments)
}

private extension String {
    func asScriptPath() -> String {
        var value = self

        if !hasSuffix(".swift") {
            value += ".swift"
        }

        if !hasPrefix("/") {
            value = value.fullPath
        }

        return value
    }

    var fullPath: String {
        if hasPrefix("/") {
            return self
        } else {
            return FileManager.default.currentDirectoryPath.appendingPath(self)
        }
    }

    var nameExcludingExtension: String {
        guard let `extension` = `extension` else {
            return fileName
        }

        let endIndex = fileName.index(fileName.endIndex, offsetBy: -`extension`.count - 1)
        return String(fileName[..<endIndex])
    }

    var `extension`: String? {
        let components = fileName.components(separatedBy: ".")

        guard components.count > 1 else {
            return nil
        }

        return components.last
    }

    var fileName: String {
        components(separatedBy: "/").last ?? "Dangerfile.swift"
    }

    var folderPath: String {
        components(separatedBy: "/").dropLast().joined(separator: "/")
    }
}
