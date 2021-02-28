import Foundation
import Logger
import ShellRunner
import Version

public struct PackageManager {
    enum Errors: Error {
        case failedToUpdatePackages(String)
        case unrecognizedTagFormat(String)
    }

    private let folder: String
    private let generatedFolder: String
    private let temporaryFolder: String
    private let packageListMaker: PackageListMaker
    private let packageGenerator: PackageGenerator
    private let fileCreator: FileCreating
    private let fileReader: FileReading
    private let packageDataProvider: PackageDataProviding
    private let logger: Logger
    private var masterPackageName: String { "PACKAGES" }

    // MARK: - Init

    public init(folder: String,
                logger: Logger) throws {
        try self.init(folder: folder,
                      fileReader: FileReader(),
                      fileCreator: FileCreator(),
                      packageDataProvider: PackageDataProvider(logger: logger),
                      logger: logger)
    }

    init(folder: String,
         fileReader: FileReading,
         fileCreator: FileCreating,
         packageDataProvider: PackageDataProviding,
         logger: Logger) throws {
        self.folder = folder
        self.fileReader = fileReader
        self.fileCreator = fileCreator
        self.logger = logger
        self.packageDataProvider = packageDataProvider
        generatedFolder = try folder.createSubfolderIfNeeded(withName: "Generated")
        temporaryFolder = try folder.createSubfolderIfNeeded(withName: "Temp")
        packageGenerator = PackageGenerator(folder: folder, generatedFolder: generatedFolder)
        packageListMaker = PackageListMaker(folder: folder, fileManager: .default, dataReader: FileReader())
    }

    func addPackagesIfNeeded(from packages: [InlineDependenciesFinder.InlineDependency]) throws {
        let existingPackageURLs = Set(packageListMaker.makePackageList().map { package in
            package.url.absoluteString.lowercased()
        })

        for package in packages {
            guard !existingPackageURLs.contains(package.url.absoluteString.lowercased()) else {
                continue
            }

            try addPackage(package)
        }
    }

    func addPackage(_ package: InlineDependenciesFinder.InlineDependency) throws {
        let name = try packageDataProvider.nameOfPackage(at: package.url, temporaryFolder: temporaryFolder)

        let latestVersion: Int
        if let major = package.major {
            latestVersion = major
        } else {
            latestVersion = try packageDataProvider.latestMajorVersionForPackage(at: package.url)
        }
        let package = Package(name: name, url: absoluteRepositoryURL(from: package.url), majorVersion: latestVersion)
        try save(package: package)

        try updatePackages()
        try addMissingPackageFiles()
    }

    private func save(package: Package) throws {
        try fileCreator.createFile(atPath: folder.appendingPath(package.name), contents: package.encoded())
    }

    private func addMissingPackageFiles() throws {
        for pinnedPackage in try packageDataProvider.resolvePinnedPackages(generatedFolder: generatedFolder) {
            guard !folder.containsItem(named: pinnedPackage.name) else {
                continue
            }

            let package = Package(
                name: pinnedPackage.name,
                url: pinnedPackage.url,
                majorVersion: pinnedPackage.state.version.major
            )

            try save(package: package)
        }
    }

    private func absoluteRepositoryURL(from url: URL) -> URL {
        guard !url.isForRemoteRepository else {
            return url
        }

        let path = url.absoluteString
        return URL(string: path)!
    }

    func symlinkPackages(to folder: String) throws {
        let checkoutsFolder = generatedFolder.appendingPath(".build/checkouts")
        let repositoriesFolder = generatedFolder.appendingPath(".build/repositories")
        let resolvedPackageFile = generatedFolder.appendingPath("Package.resolved")

        guard FileManager.default.fileExists(atPath: checkoutsFolder),
            FileManager.default.fileExists(atPath: repositoriesFolder)
        else {
            try updatePackages()
            return try symlinkPackages(to: folder)
        }

        let buildFolder = try folder.createSubfolderIfNeeded(withName: ".build")

        if !buildFolder.containsItem(named: "checkouts") {
            try buildFolder.createSymlink(to: checkoutsFolder, at: "checkouts")
        }

        if !buildFolder.containsItem(named: "repositories") {
            try buildFolder.createSymlink(to: repositoriesFolder, at: "repositories")
        }

        if !folder.containsItem(named: "Package.resolved") {
            try folder.createSymlink(to: resolvedPackageFile, at: "Package.resolved")
        }
    }

    func makePackageDescription(for script: Script) throws -> Data {
        guard let masterDescription = try? String(contentsOfFile: generatedFolder.appendingPath("Package.swift")) else {
            try updatePackages()
            return try makePackageDescription(for: script)
        }

        let toolsVersion = try resolveSwiftToolsVersion(shell: ShellRunner(), onFolder: generatedFolder)
        let expectedHeader = packageGenerator.makePackageDescriptionHeader(forSwiftToolsVersion: toolsVersion)

        guard masterDescription.hasPrefix(expectedHeader) else {
            try packageGenerator.generateMasterPackageDescription(forSwiftToolsVersion: toolsVersion)
            return try makePackageDescription(for: script)
        }

        return Data(masterDescription
            .replacingOccurrences(of: masterPackageName, with: script.name)
            .utf8)
    }

    private func updatePackages() throws {
        logger.logInfo("Updating packages...")

        do {
            let shell = ShellRunner()

            let toolsVersion = try resolveSwiftToolsVersion(shell: shell, onFolder: generatedFolder)
            try packageGenerator.generateMasterPackageDescription(forSwiftToolsVersion: toolsVersion)
            try executeSwiftCommand("package update", onFolder: generatedFolder, arguments: [], shell: shell)
            try generatedFolder.createSubfolderIfNeeded(withName: "Packages")
        } catch {
            throw Errors.failedToUpdatePackages(folder)
        }
    }

    private func resolveSwiftToolsVersion(shell: ShellRunner, onFolder _: String) throws -> Version {
        var versionString: String? = try executeSwiftCommand("package",
                                                             onFolder: folder,
                                                             arguments: ["--version"],
                                                             shell: shell)
        versionString = versionString?.onlyNumbersAndDots
        return Version(versionString ?? "") ?? .null
    }
}

extension String {
    private enum Errors: Error {
        case folderCreationFailed(String)
    }

    private var fileManager: FileManager {
        .default
    }

    @discardableResult
    func createSubfolderIfNeeded(withName folderName: String) throws -> String {
        let folderPath = appendingPath(folderName)
        if fileManager.fileExists(atPath: folderPath) {
            return folderPath
        } else {
            return try createSubfolder(folderPath: folderPath)
        }
    }

    func createSubfolder(withName name: String) throws -> String {
        try createSubfolder(folderPath: appendingPath(name))
    }

    func containsItem(named item: String) -> Bool {
        (try? fileManager.contentsOfDirectory(atPath: self).contains(item)) ?? false
    }

    func createSymlink(to originalPath: String, at linkPath: String) throws {
        let shell = ShellRunner()
        try shell.spawn("cd \(self) && ln -s \"\(originalPath)\" \"\(linkPath)\"", arguments: [])
    }

    private func createSubfolder(folderPath: String) throws -> String {
        do {
            try fileManager.createDirectory(atPath: folderPath, withIntermediateDirectories: true, attributes: nil)
            return folderPath
        } catch {
            throw Errors.folderCreationFailed(folderPath)
        }
    }

    func appendingPath(_ path: String) -> String {
        if hasSuffix("/") {
            return self + path
        } else {
            return self + "/" + path
        }
    }

    fileprivate func deletingPrefix(_ prefix: String) -> String {
        guard hasPrefix(prefix) else { return self }
        return String(dropFirst(prefix.count))
    }

    var onlyNumbersAndDots: String? {
        var charset = CharacterSet.decimalDigits
        charset.insert(".")
        return String(unicodeScalars.filter(charset.contains))
    }
}
