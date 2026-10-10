#if canImport(PorchlightMac)
import Foundation
import PorchlightCore
import PorchlightMac

/// `porchlight companion`: stands in for the app's listener and prints each report, so the mod
/// can be checked without the app. It never answers a session; like the app in this version, it
/// only listens.
func companion() async {
    let hub = CompanionHub(onEvent: { event in
        print(event.line)
        fflush(stdout)
    })
    let listener = CompanionListener(hub: hub)
    do {
        try listener.start()
    } catch CompanionListener.StartFailure.alreadyRunning {
        fail("Porchlight is already listening on \(listener.paths.socket.path). Quit the app to use this.")
    } catch {
        fail("could not listen on \(listener.paths.socket.path): \(error)")
    }
    print("listening on \(listener.paths.socket.path); Ctrl-C to stop")
    fflush(stdout)
    // Leave nothing behind for a mod to find.
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let interrupted = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let terminated = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    for source in [interrupted, terminated] {
        source.setEventHandler {
            listener.stop()
            exit(0)
        }
        source.resume()
    }
    while true { try? await Task.sleep(for: .seconds(3600)) }
}
#endif
