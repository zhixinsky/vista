import Foundation

/// Backend eligibility is separate from verified access to the wallpaper cache.
enum CarPlayCompatibility {
    enum Backend: String {
        case containerAccess
        case kernelDirect
    }

    static func candidateBackend(version: String, build: String, machine: String) -> Backend? {
        guard let parts = components(version) else { return nil }
        let major = parts[0]
        let minor = parts.count > 1 ? parts[1] : 0
        let patch = parts.count > 2 ? parts[2] : 0
        let kernelVersion = (major == 17 && minor <= 7) ||
            (major == 18 && (minor < 7 || (minor == 7 && patch <= 1)))
        if kernelVersion && kernelMachineCovered(machine) {
            return .kernelDirect
        }
        if major == 26 { return .containerAccess }
        if major == 27 && (minor < 3 || (minor == 3 && build == "24C5037i")) {
            return .containerAccess
        }
        return nil
    }

    // The two-argument overload preserves the legacy container route.
    static func supported(version: String, build: String) -> Bool {
        candidateBackend(version: version, build: build, machine: "") == .containerAccess
    }

    static func supported(version: String, build: String, machine: String) -> Bool {
        candidateBackend(version: version, build: build, machine: machine) != nil
    }

    private static func components(_ version: String) -> [Int]? {
        let tokens = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(tokens.count) else { return nil }
        var values: [Int] = []
        for token in tokens {
            guard !token.isEmpty, token.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(token) else { return nil }
            values.append(value)
        }
        return values
    }

    private static func kernelMachineCovered(_ machine: String) -> Bool {
        guard machine.hasPrefix("iPhone") else { return false }
        let identifiers = machine.dropFirst(6).split(separator: ",", omittingEmptySubsequences: false)
        guard identifiers.count == 2,
              let family = Int(identifiers[0]), let variant = Int(identifiers[1]), variant > 0 else { return false }
        return (11...17).contains(family)
    }
}
