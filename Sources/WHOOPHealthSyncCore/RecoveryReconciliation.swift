import Foundation

public enum RecoveryDecision: Equatable, Sendable {
    case write(fingerprint: String, version: Int)
    case unchanged(fingerprint: String, version: Int)
    case pending, unscorable, invalid, deferredAccess, skippedExternal, pausedNativeExport
}
public enum RecoveryReconciler {
    public static func plan(recovery: WhoopRecovery, local: RecoverySyncRecord?,
                            samples: [ExistingRecoverySample], access: HealthReadAccess,
                            appBundle: String, officialWhoopBundle: String?) throws -> RecoveryDecision {
        if case .nativeExporter = access { return .pausedNativeExport }
        if recovery.scoreState == .pending { return .pending }
        if recovery.scoreState == .unscorable { return .unscorable }
        let fingerprint: String, coverage: TimeRange
        do { fingerprint = try recovery.fingerprint(); coverage = try recovery.coverageWindow() }
        catch { return .invalid }
        guard access.covers(coverage) else { return .deferredAccess }
        let external = samples.filter { sample in
            sample.method == "RMSSD" && !sample.isOwned(appBundle: appBundle)
        }
        if let officialWhoopBundle, external.contains(where: { $0.sourceBundle == officialWhoopBundle }) {
            return .pausedNativeExport
        }
        if external.contains(where: { sample in
            sample.range.start == sample.range.end
                ? sample.range.start >= coverage.start && sample.range.start < coverage.end
                : sample.range.overlaps(coverage)
        }) { return .skippedExternal }
        let own = samples.filter { $0.isOwned(appBundle: appBundle) && $0.identifier == recovery.identifier }
        let maxVersion = max(local?.version ?? 0, own.map(\.version).max() ?? 0)
        // HealthKit is authoritative after a save/commit crash. Local-only records do not prove a sample exists.
        if let visible = own.max(by: { $0.version < $1.version }), visible.fingerprint == fingerprint {
            return .unchanged(fingerprint: fingerprint, version: visible.version)
        }
        if let local, recovery.updatedAt < local.sourceUpdatedAt, local.fingerprint != fingerprint {
            return .invalid // Never replace newer content with an older revision.
        }
        guard maxVersion < Int.max else { throw RecoverySyncError.versionOverflow }
        return .write(fingerprint: fingerprint, version: maxVersion + 1)
    }
}
