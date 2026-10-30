import AppKit
import AVKit

final class FullscreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// 元数据只负责显示，鼠标操作继续传给下方的图片。
final class MetadataOverlayStack: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class ImageCanvas: NSView {
    var allowsZoom = true { didSet { if !allowsZoom { actualSize = false } } }
    var image: NSImage? { didSet { needsDisplay = true } }
    var message = "选择一张图片" { didSet { needsDisplay = true } }
    var actualSize = false { didSet { offset = .zero; needsDisplay = true; window?.invalidateCursorRects(for:self); onZoom?() } }
    var offset = CGPoint.zero
    var onNavigate: ((Int) -> Void)?
    var onZoom: (() -> Void)?
    var requestZoom: ((Bool) -> Void)?
    private var lastPoint = CGPoint.zero
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    var scale: CGFloat {
        guard let image = image else { return 1 }
        if actualSize { return 1 / (window?.backingScaleFactor ?? 2) }
        return min(bounds.width / image.size.width, bounds.height / image.size.height)
    }
    func pan(_ x: CGFloat, _ y: CGFloat) {
        offset.x += x; offset.y += y; clamp(); needsDisplay = true
    }
    private func clamp() {
        guard let image = image else { return }
        let x = max(0,(image.size.width * scale - bounds.width) / 2)
        let y = max(0,(image.size.height * scale - bounds.height) / 2)
        offset.x = min(x,max(-x,offset.x)); offset.y = min(y,max(-y,offset.y))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite:0.065,alpha:1).setFill(); bounds.fill()
        guard let image = image else {
            let attrs: [NSAttributedString.Key:Any] = [.foregroundColor:NSColor.secondaryLabelColor,.font:NSFont.systemFont(ofSize:14)]
            let size = message.size(withAttributes:attrs)
            message.draw(at:NSPoint(x:max(12,(bounds.width-size.width)/2),y:bounds.midY),withAttributes:attrs); return
        }
        clamp()
        let size = NSSize(width:image.size.width * scale,height:image.size.height * scale)
        image.draw(in:NSRect(x:(bounds.width-size.width)/2+offset.x,y:(bounds.height-size.height)/2+offset.y,width:size.width,height:size.height),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self); lastPoint = convert(event.locationInWindow,from:nil)
        if allowsZoom && event.clickCount == 2 { if let requestZoom = requestZoom { requestZoom(!actualSize) } else { actualSize.toggle() } }
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow,from:nil)
        if actualSize { pan(point.x-lastPoint.x,point.y-lastPoint.y) }
        lastPoint = point
    }
    override func scrollWheel(with event: NSEvent) {
        if actualSize { pan(-event.scrollingDeltaX,-event.scrollingDeltaY) } else { super.scrollWheel(with:event) }
    }
    override func magnify(with event: NSEvent) { if allowsZoom && abs(event.magnification) > 0.025 { if let requestZoom = requestZoom { requestZoom(event.magnification > 0) } else { actualSize = event.magnification > 0 } } }
    override func resetCursorRects() { if actualSize { addCursorRect(bounds,cursor:.openHand) } }
}

final class ThumbnailCell: NSCollectionViewItem {
    let picture = NSImageView()
    let label = NSTextField(labelWithString:"")
    let badge = NSTextField(labelWithString:"")
    let tagsLabel = NSTextField(labelWithString:"")
    var requestID = UUID()
    var representedURL: URL?
    override func loadView() {
        view = NSView(); view.wantsLayer = true; view.layer?.cornerRadius = 8
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.setContentCompressionResistancePriority(.init(1),for:.vertical)
        label.setContentCompressionResistancePriority(.required,for:.vertical)
        badge.setContentCompressionResistancePriority(.required,for:.vertical)
        label.font = .systemFont(ofSize:11); label.lineBreakMode = .byTruncatingMiddle; label.alignment = .center
        badge.font = .monospacedSystemFont(ofSize:9,weight:.medium); badge.textColor = .secondaryLabelColor; badge.alignment = .center
        for v in [picture,label,badge] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
        tagsLabel.font = .systemFont(ofSize:10,weight:.semibold); tagsLabel.alignment = .center; tagsLabel.lineBreakMode = .byTruncatingTail
        tagsLabel.drawsBackground = true; tagsLabel.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        tagsLabel.wantsLayer = true; tagsLabel.layer?.cornerRadius = 4; tagsLabel.layer?.masksToBounds = true
        tagsLabel.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(tagsLabel)
        NSLayoutConstraint.activate([tagsLabel.topAnchor.constraint(equalTo:view.topAnchor,constant:5),tagsLabel.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:5),tagsLabel.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-5),tagsLabel.heightAnchor.constraint(equalToConstant:17)])
        NSLayoutConstraint.activate([
            label.heightAnchor.constraint(equalToConstant:16),badge.heightAnchor.constraint(equalToConstant:12),
            picture.topAnchor.constraint(equalTo:view.topAnchor,constant:8), picture.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:8),picture.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-8),picture.bottomAnchor.constraint(equalTo:label.topAnchor,constant:-6),
            label.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:6),label.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-6),label.bottomAnchor.constraint(equalTo:badge.topAnchor,constant:-3),
            badge.leadingAnchor.constraint(equalTo:view.leadingAnchor),badge.trailingAnchor.constraint(equalTo:view.trailingAnchor),badge.bottomAnchor.constraint(equalTo:view.bottomAnchor,constant:-8)])
    }
    override var isSelected: Bool { didSet { view.layer?.backgroundColor = (isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.22) : NSColor.clear).cgColor; view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor; view.layer?.borderWidth = isSelected ? 1 : 0 } }
    func configure(_ item: MediaItem, tags: Set<PhotoTag> = [], available: Bool = true) {
        let token = UUID(); requestID = token
        representedURL = item.url; label.stringValue = item.name; view.toolTip = item.url.path
        tagsLabel.stringValue = PhotoTag.text(tags); tagsLabel.isHidden = tags.isEmpty
        tagsLabel.textColor = tags.contains(.pendingDelete) ? .systemOrange : .systemGreen
        badge.stringValue = (item.isVideo ? "▶ " : "") + item.url.pathExtension.uppercased()
        picture.image = NSImage(systemSymbolName:item.isVideo ? "film" : "photo",accessibilityDescription:nil)
        if !available { badge.stringValue += " · 不可用"; return }
        MediaLoader.shared.image(item,pixels:400) { [weak self] image in
            guard self?.representedURL == item.url, self?.requestID == token else { return }; if let image = image { self?.picture.image = image }
        }
    }
}

final class FolderNode {
    let url: URL
    var children: [FolderNode]?
    init(_ url: URL) { self.url = url }
    func load() -> [FolderNode] {
        if let children = children { return children }
        children = ((try? FileManager.default.contentsOfDirectory(at:url,includingPropertiesForKeys:[.isDirectoryKey,.isPackageKey],options:[.skipsHiddenFiles])) ?? []).filter {
            let values = try? $0.resourceValues(forKeys:[.isDirectoryKey,.isPackageKey])
            return values?.isDirectory == true && values?.isPackage != true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.map(FolderNode.init)
        return children ?? []
    }
}
