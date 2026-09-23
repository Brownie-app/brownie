import Foundation

/// Live progress of a run. Sensitive items publish NO title or summary — only the count moves.
public struct RunProgress: Sendable, Equatable {
    public enum Stage: String, Sendable { case reading, synthesising, judging, preparing, finishing, done }
    public var stage: Stage
    public var sourceName: String
    public var bucketName: String
    public var bucketIndex: Int
    public var bucketCount: Int
    public var itemIndex: Int
    public var itemCount: Int
    public var stats: RunStats
    public var lastTitle: String?
    public var lastSummary: String?
    public var thought: String?
    public var partIndex: Int?
    public var partCount: Int?

    public init(stage: Stage = .reading, sourceName: String = "", bucketName: String = "", bucketIndex: Int = 0, bucketCount: Int = 0,
                itemIndex: Int = 0, itemCount: Int = 0, stats: RunStats = RunStats(), lastTitle: String? = nil, lastSummary: String? = nil,
                thought: String? = nil, partIndex: Int? = nil, partCount: Int? = nil) {
        self.stage = stage; self.sourceName = sourceName; self.bucketName = bucketName; self.bucketIndex = bucketIndex; self.bucketCount = bucketCount
        self.itemIndex = itemIndex; self.itemCount = itemCount; self.stats = stats; self.lastTitle = lastTitle; self.lastSummary = lastSummary
        self.thought = thought; self.partIndex = partIndex; self.partCount = partCount
    }
}
