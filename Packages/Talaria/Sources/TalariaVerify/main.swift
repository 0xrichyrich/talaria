import Foundation
import TalariaKit

do {
    try ProtocolChecks.runAll()
    print("talaria-verify: all protocol checks passed ✓")
} catch {
    print("talaria-verify: \(error)")
    exit(1)
}
