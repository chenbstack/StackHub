import Foundation

enum ServiceShell {
    static func makeProcess(command: String, directory: URL, runtime: ServiceRuntimeResolution? = nil) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Use an interactive login shell so .zprofile, .zshrc, and .zlogin
        // configure PATH and tools such as jenv/nvm in the service directory.
        // exec keeps the launched command as the tracked process for stopping.
        // Apply the resolved environment after startup files. Positional
        // parameters keep paths containing quotes, spaces, or $() as data.
        var setup = ""
        var paths: [String] = []
        if let java = runtime?.java.installation {
            paths.append(java.path)
            setup += "export JAVA_HOME=\"$\(paths.count)\"\nexport PATH=\"$JAVA_HOME/bin:$PATH\"\n"
        }
        if let node = runtime?.node.installation {
            paths.append(node.binDirectory)
            setup += "export PATH=\"$\(paths.count):$PATH\"\n"
        }
        // Do not leak our positional parameters to user commands.
        if !paths.isEmpty { setup += "set --\n" }
        process.arguments = ["-lic", setup + "exec \(command)", "stackhub-service"] + paths
        process.currentDirectoryURL = directory
        return process
    }
}
