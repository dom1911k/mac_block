import Foundation
import Darwin
import IntentCore

// intentmoded — the Intent Mode enforcement daemon (runs as root, started by intentguard via launchd).
//
//   intentmoded                 run the daemon
//   intentmoded --self-test     check this build against a config (used before installing updates)
//       [--config <path>]

let args = CommandLine.arguments
setvbuf(stdout, nil, _IOLBF, 0)

if args.contains("--self-test") {
    exit(SelfTest.main(args))
}
if args.contains("--version") {
    print(BuildInfo.version)
    exit(0)
}
guard getuid() == 0 else {
    FileHandle.standardError.write(Data("intentmoded must run as root (it is started by launchd).\n".utf8))
    exit(1)
}

signal(SIGPIPE, SIG_IGN)
umask(0o022)

let daemon = Daemon()
daemon.start()

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler {
        daemon.shutdown()
        exit(0)
    }
    s.resume()
    signalSources.append(s)
}

dispatchMain()
