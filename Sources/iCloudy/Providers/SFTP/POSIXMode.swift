import Foundation

/// The permission bits of a file on a Unix server: who may read, write and run it.
struct POSIXMode: Equatable, Hashable {
    /// The twelve low bits: the nine permissions and setuid, setgid and sticky.
    var bits: UInt32

    init(bits: UInt32) { self.bits = bits & 0o7777 }
    /// "755", "0644", "4755". Nil for anything that is not octal or does not fit.
    init?(octal text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard (3...4).contains(trimmed.count), let value = UInt32(trimmed, radix: 8), value <= 0o7777 else { return nil }
        bits = value
    }

    enum Who: Int, CaseIterable { case owner = 6, group = 3, others = 0 }
    enum What: UInt32, CaseIterable { case read = 4, write = 2, execute = 1 }

    func allows(_ what: What, _ who: Who) -> Bool { bits & (what.rawValue << UInt32(who.rawValue)) != 0 }
    mutating func set(_ what: What, _ who: Who, _ allowed: Bool) {
        let bit = what.rawValue << UInt32(who.rawValue)
        bits = allowed ? bits | bit : bits & ~bit
    }

    /// "755"; four digits only when one of the special bits is set.
    var octal: String { String(bits, radix: 8).leftPadded(to: bits > 0o777 ? 4 : 3) }
    /// "rwxr-xr-x", the way `ls -l` writes it, special bits included.
    var symbolic: String {
        var text = ""
        for who in Who.allCases {
            text += allows(.read, who) ? "r" : "-"
            text += allows(.write, who) ? "w" : "-"
            let runs = allows(.execute, who)
            let special: (bit: UInt32, set: Character, alone: Character)
            switch who {
            case .owner: special = (0o4000, "s", "S")
            case .group: special = (0o2000, "s", "S")
            case .others: special = (0o1000, "t", "T")
            }
            if bits & special.bit != 0 { text.append(runs ? special.set : special.alone) } else { text += runs ? "x" : "-" }
        }
        return text
    }
}

private extension String {
    func leftPadded(to length: Int) -> String { String(repeating: "0", count: max(0, length - count)) + self }
}
