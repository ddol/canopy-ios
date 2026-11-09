import CanopyModel
import CanopyStore
import Foundation

// MARK: - Tags

extension AppModel {
    /// A limb mesh to keep as evidence with a tag.
    struct LimbEvidence {
        var glb: Data
        var vertexCount: Int
        var triangleCount: Int
        var cropRadius: Double
    }

    /// Places a hazard tag on a tree, with optional limb evidence. The tag starts as proposed.
    ///
    /// As with trunk scans, a limb scan already saved (Save tapped twice) adds nothing: it returns the scan's tag, and a
    /// save of the same scan while one is still running returns nil at once.
    @discardableResult
    func placeTag(
        on tree: Tree, point: Tag.Point, issue: Tag.Issue, couldHit: Tag.Target, sizeClass: Tag.SizeClass,
        urgency: Tag.Urgency, evidence: LimbEvidence?
    ) async -> Tag? {
        var tagID = UUID()
        let chunk = point.position.chunk
        var evidenceRef: BlobRef?
        let blob = evidence.map { BlobStore.reference(for: $0.glb) }
        if let blob {
            guard scansBeingSaved.insert(blob).inserted else { return nil }
        }
        defer { if let blob { scansBeingSaved.remove(blob) } }
        do {
            if let evidence, let blob {
                if let saved = try await store.evidence(hash: blob), let tag = census.tags[saved.subjectID] {
                    return tag
                }
                let stored = try await store.addEvidence(
                    Evidence(
                        meta: RecordMeta(playerID: player.id, chunk: chunk),
                        blob: blob,
                        byteCount: evidence.glb.count,
                        kind: .limbScan,
                        subjectID: tagID,
                        cropRadius: evidence.cropRadius,
                        vertexCount: evidence.vertexCount,
                        triangleCount: evidence.triangleCount
                    ),
                    data: evidence.glb
                )
                // A record already stored for this scan names the tag it is about.
                tagID = stored.subjectID
                evidenceRef = blob
            }
        } catch {
            self.error = "Could not save the limb scan: \(error.localizedDescription)"
            return nil
        }
        let tag = Tag(
            meta: RecordMeta(id: tagID, playerID: player.id, chunk: chunk),
            treeID: tree.id,
            point: point,
            issue: issue,
            couldHit: couldHit,
            sizeClass: sizeClass,
            urgency: urgency,
            evidenceRef: evidenceRef
        )
        guard await record(.tagPlaced(tag)) != nil else { return nil }
        return census.tags[tag.id]
    }

    func tags(on tree: Tree) -> [Tag] {
        census.tags.values.filter { $0.treeID == tree.id }.sorted { $0.meta.createdAt > $1.meta.createdAt }
    }
}
