import Foundation
import Logger

#if os(Linux)
    import Glibc
#else
    import Darwin.C
#endif

final class DangerRunner {
    static let shared = DangerRunner()

    let logger: Logger
    let dsl: DangerDSL
    let outputPath: String
    var results = DangerResults() {
        didSet {
            dumpResults()
        }
    }

    private init() {
        let isVerbose = CommandLine.arguments.contains("--verbose") || ProcessInfo.processInfo.environment["DEBUG"] != nil
        let isSilent = CommandLine.arguments.contains("--silent")

        logger = Logger(isVerbose: isVerbose, isSilent: isSilent)

        logger.debug(
            """
            \(type(of: self)) arguments:
            \(CommandLine.arguments.enumerated().map { "\t\($0): \($1)" }.joined(separator: "\n"))
            """
        )

        let argumentsCount = CommandLine.arguments.count

        guard argumentsCount - 2 > 0 else {
            logger.logError("To execute Danger run danger-swift ci, " +
                "danger-swift pr or danger-swift local on your terminal")
            exit(1)
        }

        let dslJsonArg: String? = CommandLine.arguments[argumentsCount - 2]
        let outputJSONPath = CommandLine.arguments[argumentsCount - 1]

        guard let dslJsonPath = dslJsonArg else {
            logger.logError("could not find DSL JSON arg")
            exit(1)
        }

        guard let dslJsonData = FileManager.default.contents(atPath: dslJsonPath) else {
            logger.logError("could not find DSL JSON at path: \(dslJsonPath)")
            exit(1)
        }
        do {
            logger.debug("Decoding the DSL at \(dslJsonPath)")
            logger.debug("DSL content:\n\(String(data: dslJsonData, encoding: .utf8)!)")

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom(DateFormatter.dateFormatterHandler)
            dsl = try decoder.decode(DSL.self, from: dslJsonData).danger
        } catch {
            logger.logError("Failed to parse JSON:", error)
            exit(1)
        }

        logger.debug("Setting up to dump results")
        outputPath = outputJSONPath
        dumpResults()
    }

    private func dumpResults() {
        logger.debug("Sending results back to Danger")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(results)

            if !FileManager.default.createFile(atPath: outputPath,
                                               contents: data,
                                               attributes: nil) {
                logger.logError("Could not create a temporary file " +
                    "for the Dangerfile DSL at: \(outputPath)")
                exit(0)
            }

        } catch {
            logger.logError("Failed to generate result JSON:", error)
            exit(1)
        }
    }
}

// MARK: - Public Functions

// swiftlint:disable:next identifier_name
public func Danger() -> DangerDSL {
    DangerRunner.shared.dsl
}
