import AppKit

final class BrowserTableView: NSTableView {
    var menuAtRow: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        menuAtRow?(row(at: convert(event.locationInWindow, from: nil)))
    }
}

final class BrowserOutlineView: NSOutlineView {
    var menuAtRow: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        menuAtRow?(row(at: convert(event.locationInWindow, from: nil)))
    }
}

final class BrowserCollectionView: NSCollectionView {
    var menuAtItem: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return menuAtItem?(index.item)
    }
}

extension BrowserController {
    func contextMenu(at index: Int) -> NSMenu? {
        guard items.indices.contains(index) else { return nil }
        select(index)
        return itemMenu(items[index])
    }

    func itemMenu(_ item: MediaItem) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
            let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.representedObject = item
            entry.isEnabled = enabled
            return entry
        }
        _ = add("在 Finder 打开", #selector(revealInFinder))
        if item.isDirectory {
            _ = add("进入文件夹", #selector(enterContextFolder))
            return menu
        }
        let available = !fileOperationRunning && isFileAvailable(item)
        _ = add("复制到…", #selector(copyContextFile), enabled: available)
        _ = add("移动到…", #selector(moveContextFile), enabled: available)
        menu.addItem(.separator())
        let tags = flags(for: item.url)
        for (tag, title, action) in [
            (PhotoTag.chosen, "标记为选择", #selector(markContextChosen)),
            (PhotoTag.pendingDelete, "标记为待删除", #selector(markContextPending))
        ] {
            _ = add(tags.contains(tag) ? "取消“\(tag.title)”标记" : title, action, enabled: available || (!fileOperationRunning && reviewingTag && tags.contains(tag)))
        }
        return menu
    }

    @objc private func revealInFinder(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? MediaItem else { return }
        if item.isDirectory { NSWorkspace.shared.open(item.url) }
        else { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
    }

    @objc private func enterContextFolder(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? MediaItem else { return }
        enterFolder(item.url)
    }

    func enterFolder(_ url: URL) {
        search.stringValue = ""
        openFolder(url)
    }

    @objc private func markContextChosen(_ sender: NSMenuItem) { markContextFile(.chosen, sender) }
    @objc private func markContextPending(_ sender: NSMenuItem) { markContextFile(.pendingDelete, sender) }

    private func markContextFile(_ tag: PhotoTag, _ sender: NSMenuItem) {
        guard let item = sender.representedObject as? MediaItem,
              let index = items.firstIndex(where: { $0.url == item.url }) else { return }
        select(index)
        toggleTag(tag)
    }

    @objc private func copyContextFile(_ sender: NSMenuItem) { chooseContextDestination(.copy, sender) }
    @objc private func moveContextFile(_ sender: NSMenuItem) { chooseContextDestination(.move, sender) }

    private func chooseContextDestination(_ action: FileBatchAction, _ sender: NSMenuItem) {
        guard !fileOperationRunning, let item = sender.representedObject as? MediaItem,
              let window else { return }
        do {
            let snapshot: TaggedFile
            if let record = tagStore.record(for: item.url) { snapshot = record }
            else { snapshot = TaggedFile(id: UUID(), url: item.url, identity: try TaggedFileIdentity.capture(item.url), tags: []) }
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.directoryURL = folder
            panel.title = "\(action.title)“\(item.name)”"
            panel.prompt = "\(action.title)到此目录"
            panel.beginSheetModal(for: window) { [weak self] result in
                guard result == .OK, let destination = panel.url else { return }
                self?.runFileBatch(action, files: [snapshot], destination: destination)
            }
        } catch { showError("\(action.title)失败", error: error) }
    }
}
