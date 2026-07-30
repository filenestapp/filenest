import Foundation

@main
struct FileNestSkillCLI {
    static func main() {
        do {
            let arguments = CommandLine.arguments
            let command = Array(arguments.dropFirst())
            // Do not read terminal stdin for `skill list` (or explicit JSON/file input).
            // `readDataToEndOfFile()` blocks until EOF when invoked interactively.
            let readsStandardInput = command.count == 3
                && command[0] == "skill"
                && command[1] == "run"
            let output = try SkillToolCommandLine.execute(
                arguments: arguments,
                standardInput: readsStandardInput
                    ? FileHandle.standardInput.readDataToEndOfFile()
                    : Data()
            )
            FileHandle.standardOutput.write(output)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            FileHandle.standardError.write(Data("filenest: \(message)\n".utf8))
            exit(1)
        }
    }
}
