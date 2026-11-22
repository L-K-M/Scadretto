import ScadrettoCore
import ScadrettoEngineClient

/// The call path that re-identifies a selection in a later evaluation.
public struct SelectionPath: Equatable, Sendable {
    public struct Anchor: Equatable, Sendable {
        public let name: String
        public let iteration: [String: Double]
        public let dependency: String?
        public internal(set) var start: Int?
    }

    public enum Match: Equatable, Sendable {
        case exact(UInt32)
        case ancestor(UInt32)
    }

    public private(set) var anchors: [Anchor]
    /// An edit removed the selected statement, so only an ancestor remains.
    private var lostSelection = false
    /// How far above the selection the nearest removed wrapper was.
    private var removedDistance: Int?
    /// Text written since the selection was resolved. A wrapper authored there
    /// is a new ancestor of the same selection.
    private var inserted: [Range<Int>] = []

    public init(to id: UInt32, in scene: SceneSnapshot, files: [FileRecord]) {
        let byID = Dictionary(uniqueKeysWithValues: scene.instances.map { ($0.id, $0) })
        anchors = Self.path(to: id, among: byID, files: files)
    }

    /// An exact match, otherwise the nearest authored ancestor. Never a sibling.
    public func resolve(in scene: SceneSnapshot, files: [FileRecord]) -> Match? {
        // One forward pass, as a parent precedes its children. An instance keeps
        // how many anchors its own authored path matches, leaving out inserted wrappers.
        var matched: [UInt32: Int] = [:]
        var candidates: [Int: [UInt32]] = [:]
        for instance in scene.instances {
            let above: Int
            if let parent = instance.parent {
                guard let depth = matched[parent] else { continue }
                above = depth
            } else {
                above = 0
            }
            let own = Self.anchor(of: instance, files: files)
            // The selection itself must keep its exact start, so an equal sibling never matches.
            let matches = above < anchors.count && own == anchors[above]
            if matches { candidates[above + 1, default: []].append(instance.id) }
            if isInserted(own) {
                matched[instance.id] = above
            } else if matches {
                matched[instance.id] = above + 1
            }
        }

        for length in stride(from: anchors.count, to: 0, by: -1) {
            let isSelection = length == anchors.count && !lostSelection
            // The unspanned root would select the whole model.
            guard isSelection || anchors[length - 1].start != nil else { continue }
            if let found = candidates[length], found.count == 1 {
                return isSelection ? .exact(found[0]) : .ancestor(found[0])
            }
        }
        return nil
    }

    /// Follows committed edits. An edit that removes a wrapper drops that
    /// anchor, and one that removes the selection leaves its ancestors. False
    /// means no authored anchor remains.
    public mutating func follow(_ edits: [SourceEdit]) -> Bool {
        let changes = edits.map(Self.change)
        func shift(_ position: Int, excluding excluded: Int? = nil) -> Int {
            var moved = position
            for (index, change) in changes.enumerated() where index != excluded && change.range.upperBound <= position {
                moved += change.length - change.range.count
            }
            return moved
        }

        var kept: [Anchor] = []
        for (index, anchor) in anchors.enumerated() {
            var anchor = anchor
            if anchor.dependency == nil, let start = anchor.start {
                if changes.contains(where: { $0.range.contains(start) }) {
                    let distance = anchors.count - 1 - index
                    if distance == 0 { lostSelection = true }
                    removedDistance = min(distance, removedDistance ?? distance)
                    continue
                }
                anchor.start = shift(start)
            }
            kept.append(anchor)
        }
        anchors = kept

        inserted = inserted.map { range in
            let lower = shift(range.lowerBound)
            return lower..<max(lower, shift(range.upperBound))
        }
        for (index, change) in changes.enumerated() where change.length > 0 {
            let lower = shift(change.range.lowerBound, excluding: index)
            inserted.append(lower..<(lower + change.length))
        }
        return anchors.contains { $0.start != nil }
    }

    /// The nearest distance above the selection at which a wrapper was
    /// inserted or removed. A property owned there or farther out has moved.
    func changedDistance(to id: UInt32, in scene: SceneSnapshot, files: [FileRecord]) -> Int? {
        let byID = Dictionary(uniqueKeysWithValues: scene.instances.map { ($0.id, $0) })
        let path = Self.path(to: id, among: byID, files: files).reversed()
        let insertedDistance = path.enumerated().first { $0.offset > 0 && isInserted($0.element) }?.offset
        return [removedDistance, insertedDistance].compactMap { $0 }.min()
    }

    private func isInserted(_ anchor: Anchor) -> Bool {
        guard anchor.dependency == nil, let start = anchor.start else { return false }
        return inserted.contains { $0.contains(start) }
    }

    /// The bytes an edit really changes. A checked insertion carries adjacent
    /// guard bytes, which must not count as removing the statement they start.
    private static func change(_ edit: SourceEdit) -> (range: Range<Int>, length: Int) {
        let old = Array(edit.expected)
        let new = Array(edit.replacement)
        var suffix = 0
        while suffix < min(old.count, new.count), old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        var prefix = 0
        while prefix < min(old.count, new.count) - suffix, old[prefix] == new[prefix] { prefix += 1 }
        let lower = edit.range.lowerBound + prefix
        return (lower..<(lower + old.count - prefix - suffix), new.count - prefix - suffix)
    }

    private static func path(to id: UInt32, among instances: [UInt32: InstanceRecord],
                             files: [FileRecord]) -> [Anchor] {
        var path: [Anchor] = []
        var next: UInt32? = id
        while let id = next, let instance = instances[id] {
            path.append(anchor(of: instance, files: files))
            next = instance.parent
        }
        return path.reversed()
    }

    private static func anchor(of instance: InstanceRecord, files: [FileRecord]) -> Anchor {
        let file = instance.span.flatMap { span in files.first { $0.id == span.fileID } }
        let dependency = file.flatMap { $0.kind == .main ? nil : $0.resolvedPath ?? $0.logicalPath }
        return Anchor(name: instance.name, iteration: instance.iteration, dependency: dependency,
                      start: instance.span.flatMap { Int(exactly: $0.start) })
    }
}
