import ScadrettoEngineClient

extension SceneSnapshot {
    /// Every rendered operand at or below these executed instances, in executed
    /// order. A parent always precedes its children.
    public func renderedOperands(below ids: [UInt32]) -> [UInt32] {
        var covered = Set(ids)
        var operands: [UInt32] = []
        for instance in instances {
            if let parent = instance.parent, covered.contains(parent) { covered.insert(instance.id) }
            if instance.operand != nil, covered.contains(instance.id) { operands.append(instance.id) }
        }
        return operands
    }

    /// Instances that remove material. A subtraction nested inside another
    /// subtraction adds it back.
    public var subtractedInstances: Set<UInt32> {
        var subtracted: Set<UInt32> = []
        for operation in operations {
            for child in operation.children where child.role == .subtracted { subtracted.insert(child.instanceID) }
        }
        var reversed: Set<UInt32> = []
        for instance in instances {
            let parentReversed = instance.parent.map(reversed.contains) ?? false
            if parentReversed != subtracted.contains(instance.id) { reversed.insert(instance.id) }
        }
        return reversed
    }
}
