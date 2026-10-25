/// Parts of Canopy that are built but switched off until they are ready.
enum Features {
    /// Tagging limb hazards: the Tag tab, "Tag a limb hazard" on a tree, and the hazard-tags map layer. Hidden for now;
    /// it comes back as an extension. The model, store and sync still handle tags, so nothing already recorded is lost.
    static let limbTagging = false
}
