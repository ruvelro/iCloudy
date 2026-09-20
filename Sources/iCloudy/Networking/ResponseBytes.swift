import Foundation
import CoreFoundation

/// Strict byte counts: booleans, fractions, negative values and overflow are not storage sizes.
enum ResponseBytes {
    static func value(_ raw: Any?) -> Int64? {
        let value: Int64?
        if let string = raw as? String { value = Int64(string) }
        else if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            value = Int64(number.stringValue)
        } else { value = nil }
        return value.flatMap { $0 >= 0 ? $0 : nil }
    }
}
