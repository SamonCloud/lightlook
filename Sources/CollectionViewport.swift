import AppKit

/// 使用真实缩略图边界直接移动 clip view，不依赖 scrollToItems 的边缘对齐提示。
struct CollectionSelectionVisibility {
    @discardableResult
    static func reveal(index: Int, collection: NSCollectionView, scrollView: NSScrollView) -> Bool {
        scrollView.layoutSubtreeIfNeeded(); collection.layoutSubtreeIfNeeded()
        guard index >= 0, index < collection.numberOfItems(inSection:0),
              let frame = collection.collectionViewLayout?.layoutAttributesForItem(at:IndexPath(item:index,section:0))?.frame else { return false }
        let clip = scrollView.contentView
        let target = collection.convert(frame,to:clip)
        let visible = clip.bounds
        guard visible.height > 0 else { return false }
        let margin: CGFloat = target.height+16 <= visible.height ? 8 : 0
        var origin = visible.origin
        if target.height > visible.height || target.minY < visible.minY+margin {
            origin.y = target.minY-margin
        } else if target.maxY > visible.maxY-margin {
            origin.y = target.maxY+margin-visible.height
        }
        let constrained = clip.constrainBoundsRect(NSRect(origin:origin,size:visible.size))
        clip.scroll(to:constrained.origin)
        scrollView.reflectScrolledClipView(clip)
        let updated = collection.convert(frame,to:clip)
        return clip.bounds.intersection(updated).height >= min(updated.height,clip.bounds.height)-0.5
    }
}
