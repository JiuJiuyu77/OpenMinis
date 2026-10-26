//
//  ICloudAvailability.swift
//  Minis
//
//  Whether this *code signature* actually carries the iCloud entitlements.
//
//  Why this exists: `CKContainer(identifier:)` raises an Objective-C exception
//  (`EXC_BREAKPOINT`) when the process is not entitled for the container. A
//  Swift `do/catch` cannot intercept an ObjC exception, so the only workable
//  defence is to never construct a CKContainer in the first place.
//
//  That is exactly what happens on an adhoc / TrollStore re-sign: the profile
//  is gone, so `com.apple.developer.icloud-container-identifiers` and
//  `com.apple.developer.icloud-services` are absent, and the previous launch
//  path crashed inside `SyncV2Bootstrap.startIfEnabled()` →
//  `ICloudSharedZoneTransport.init()` → `CKContainer(identifier:)`.
//
//  SecTask APIs are resolved with dlsym so this file compiles and links even
//  where the declarations are not exposed, and so a missing symbol degrades to
//  "assume not entitled" (the safe answer) instead of a link error.
//

import Foundation
import CoreFoundation

enum ICloudAvailability {

    static let containerIdentifier = "iCloud.com.openminis.app"

    private static let lock = NSLock()
    private static var cachedResult: Bool?

    /// True only when the running process is entitled for the iCloud
    /// container used by sync. Cheap after the first call.
    static var isEntitled: Bool {
        lock.lock()
        defer { lock.unlock() }
        if let cachedResult { return cachedResult }
        let resolved = resolveEntitlements()
        cachedResult = resolved
        return resolved
    }

    /// Escape hatch for diagnostics screens: forget the cached answer.
    static func resetCache() {
        lock.lock()
        cachedResult = nil
        lock.unlock()
    }

    /// Human-readable reason for logs / settings UI.
    static var unavailabilityReason: String? {
        isEntitled ? nil : "This build is not entitled for iCloud (\(containerIdentifier))."
    }

    // MARK: - Entitlement probing

    private typealias SecTaskRef = CFTypeRef
    private typealias CreateFromSelfFn = @convention(c) (CFAllocator?) -> SecTaskRef?
    private typealias CopyValueFn = @convention(c) (SecTaskRef?, CFString, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> CFTypeRef?

    private static let createFromSelf: CreateFromSelfFn? = {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW) else { return nil }
        guard let sym = dlsym(handle, "SecTaskCreateFromSelf") else { return nil }
        return unsafeBitCast(sym, to: CreateFromSelfFn.self)
    }()

    private static let copyEntitlement: CopyValueFn? = {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW) else { return nil }
        guard let sym = dlsym(handle, "SecTaskCopyValueForEntitlement") else { return nil }
        return unsafeBitCast(sym, to: CopyValueFn.self)
    }()

    private static func resolveEntitlements() -> Bool {
        guard let create = createFromSelf, let copy = copyEntitlement else {
            // No Security framework symbols: we cannot prove the entitlement,
            // so behave as an unentitled build. Sync stays off; the app runs.
            return false
        }
        guard let task = create(nil) else { return false }

        let groups = copy(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String]
        let services = copy(task, "com.apple.developer.icloud-services" as CFString, nil) as? [String]

        guard let groups, groups.contains(containerIdentifier) else { return false }
        // `CloudKit` is the service the sync engines use. Accept the wildcard
        // `CloudKit-Anonymous`? No — sync needs the named container, so keep it strict.
        guard let services, services.contains("CloudKit") else { return false }
        return true
    }
}
