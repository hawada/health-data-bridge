import Foundation

public struct SyncCheckpointState: Equatable, Sendable {
    public var lastHeartRateEnd: Date?
    public var lastSleepQueryEnd: Date?
    public var lastHeartRateResolution: Int?

    public init(lastHeartRateEnd: Date?, lastSleepQueryEnd: Date?, lastHeartRateResolution: Int? = nil) {
        self.lastHeartRateEnd = lastHeartRateEnd
        self.lastSleepQueryEnd = lastSleepQueryEnd
        self.lastHeartRateResolution = lastHeartRateResolution
    }
}

public struct IncrementalSyncPlan: Equatable, Sendable {
    public var syncStartedAt: Date
    public var heartRateWindow: TimeRange
    public var sleepDiscoveryWindow: TimeRange
    public var sleepRevisionLookbackWindow: TimeRange
    public var isFirstHeartRateSync: Bool
    public var isFirstSleepSync: Bool

    public init(
        syncStartedAt: Date,
        heartRateWindow: TimeRange,
        sleepDiscoveryWindow: TimeRange,
        sleepRevisionLookbackWindow: TimeRange,
        isFirstHeartRateSync: Bool,
        isFirstSleepSync: Bool
    ) {
        self.syncStartedAt = syncStartedAt
        self.heartRateWindow = heartRateWindow
        self.sleepDiscoveryWindow = sleepDiscoveryWindow
        self.sleepRevisionLookbackWindow = sleepRevisionLookbackWindow
        self.isFirstHeartRateSync = isFirstHeartRateSync
        self.isFirstSleepSync = isFirstSleepSync
    }
}

public enum SyncWindowPlanner {
    /// WHOOP uploads band data late (minutes, sometimes hours after it was recorded). Live syncs re-read this
    /// much recent heart rate so points that arrived after the last sync are still written; points already
    /// in Health are skipped by the reconciler.
    public static let liveHeartRateRevisionHours = 24

    public static func makePlan(
        now: Date,
        checkpoints: SyncCheckpointState,
        firstSyncLookbackDays: Int = 7,
        sleepRevisionLookbackDays: Int = 7,
        heartRateStepSeconds: Int = 6,
        heartRateRevisionLookbackHours: Int = 0
    ) -> IncrementalSyncPlan {
        let firstLookback = TimeInterval(firstSyncLookbackDays * 24 * 60 * 60)
        let revisionLookback = TimeInterval(sleepRevisionLookbackDays * 24 * 60 * 60)

        let firstSyncStart = now.addingTimeInterval(-firstLookback)
        let heartRateOverlapSeconds = max(heartRateStepSeconds, checkpoints.lastHeartRateResolution ?? heartRateStepSeconds)
        let heartRateRevisionStart = now.addingTimeInterval(-TimeInterval(heartRateRevisionLookbackHours * 60 * 60))
        let heartRateStart = checkpoints.lastHeartRateEnd.map {
            min($0.addingTimeInterval(-TimeInterval(heartRateOverlapSeconds)), heartRateRevisionStart)
        } ?? firstSyncStart
        let sleepStart = checkpoints.lastSleepQueryEnd ?? firstSyncStart
        let revisionStart = now.addingTimeInterval(-revisionLookback)

        return IncrementalSyncPlan(
            syncStartedAt: now,
            heartRateWindow: TimeRange(start: min(heartRateStart, now), end: now),
            sleepDiscoveryWindow: TimeRange(start: min(sleepStart, now), end: now),
            sleepRevisionLookbackWindow: TimeRange(start: min(revisionStart, now), end: now),
            isFirstHeartRateSync: checkpoints.lastHeartRateEnd == nil,
            isFirstSleepSync: checkpoints.lastSleepQueryEnd == nil
        )
    }

    public static func sleepQueryWindow(for plan: IncrementalSyncPlan) -> TimeRange {
        TimeRange(
            start: min(plan.sleepDiscoveryWindow.start, plan.sleepRevisionLookbackWindow.start),
            end: plan.syncStartedAt
        )
    }

    public static func heartRateChunks(window: TimeRange, maxChunkSeconds: TimeInterval) -> [TimeRange] {
        guard window.hasPositiveDuration, maxChunkSeconds > 0 else {
            return []
        }

        var chunks: [TimeRange] = []
        var cursor = window.start
        while cursor < window.end {
            let chunkEnd = min(cursor.addingTimeInterval(maxChunkSeconds), window.end)
            chunks.append(TimeRange(start: cursor, end: chunkEnd))
            cursor = chunkEnd
        }
        return chunks
    }
}
