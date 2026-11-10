import Foundation
import OrbCore

setvbuf(stdout, nil, _IOLBF, 0)
let argv = Array(CommandLine.arguments.dropFirst())
let cmd = argv.first ?? "help"
let rest = Array(argv.dropFirst())

await MainActor.run {} // ensure main actor initialised
switch cmd {
case "demo": await cmdDemo(rest)
case "doctor": await cmdDoctor()
case "models": await cmdModels(rest)
case "setup": await cmdSetup(rest)
case "use": await cmdUse(rest)
case "run": await cmdRun()
case "chat": await cmdChat()
case "status": await cmdStatus()
case "stop": cmdStop()
case "help", "-h", "--help": print(usage)
default: FileHandle.standardError.write(Data("unknown command '\(cmd)'\n\n\(usage)\n".utf8)); exit(2)
}
