import Foundation
import SwiftUI
import Scheduling

// The same binary doubles as the root wake helper when launchd starts it with --wake-helper.
if CommandLine.arguments.contains("--wake-helper") { WakeHelper.runDaemon() }

BrownieApp.main()
