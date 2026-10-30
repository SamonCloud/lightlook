import AppKit

extension BrowserController {
    var reviewingTag: Bool { currentTag != nil }
    func flags(for url: URL) -> Set<PhotoTag> { tagStore.flags(for:url,reviewing:reviewingTag) }
    func isFileAvailable(_ item: MediaItem) -> Bool {
        if reviewingTag, let record = tagStore.record(for:item.url) { return record.isAvailable }
        return true
    }
    func updateTagIndicators() {
        chosenTagButton.title = "✓ 已选择  (\(tagStore.files(with:.chosen).count))"
        pendingTagButton.title = "待删除  (\(tagStore.files(with:.pendingDelete).count))"
        chosenTagButton.state = currentTag == .chosen ? .on : .off
        pendingTagButton.state = currentTag == .pendingDelete ? .on : .off
        batchButton.isHidden = currentTag == nil
        batchButton.isEnabled = !fileOperationRunning
        let text = selected.map { PhotoTag.text(flags(for:$0)) } ?? ""
        fullTagLabel.stringValue = text; fullTagOverlay.isHidden = text.isEmpty
        if let item = currentItem { fileTitle.stringValue = item.name + (text.isEmpty ? "" : "  [\(text)]") }
    }
    @objc func showChosenTag() { showTag(.chosen) }
    @objc func showPendingTag() { showTag(.pendingDelete) }
    func showTag(_ tag: PhotoTag, preferredSelection: URL? = nil) {
        currentTag = tag
        let snapshot = tagStore.files(with:tag)
        let token = UUID(); scanID = token
        allItems = []; items = []; selected = nil
        collection.reloadData(); files.reloadData(); loadSelection()
        pathLabel.stringValue = "标签 · \(tag.title)（跨目录）"; pathLabel.toolTip = "包含所有目录中的此类标签，未连接磁盘的记录也会保留。"
        folderTitle.stringValue = tag.title; window?.representedURL = nil
        updateTagIndicators(); status.stringValue = "正在读取\(tag.title)标签…"
        scanQueue.async {
            let media = snapshot.map { MediaItem.read($0.url) }
            DispatchQueue.main.async {
                guard self.scanID == token, self.currentTag == tag else { return }
                self.allItems = media; self.selected = preferredSelection ?? media.first?.url
                self.filterItems(); self.window?.makeFirstResponder(self.mode.selectedSegment == 0 ? self.collection : self.files)
            }
        }
    }
    @discardableResult
    func handleTagShortcut(_ keyCode: UInt16, isARepeat: Bool) -> Bool {
        guard [UInt16(1),2,51,117].contains(keyCode) else { return false }
        if !isARepeat && !fileOperationRunning { toggleTag(keyCode == 1 ? .chosen : .pendingDelete) }
        return true
    }
    @objc func toggleChosenTag() { toggleTag(.chosen) }
    @objc func togglePendingTag() { toggleTag(.pendingDelete) }
    func toggleTag(_ tag: PhotoTag) {
        guard !fileOperationRunning, let item = currentItem else { return }
        let previousIndex = items.firstIndex(where:{$0.url == item.url}) ?? 0
        do {
            let adding = try tagStore.toggle(tag,url:item.url,reviewing:reviewingTag)
            updateTagIndicators()
            if let currentTag = currentTag {
                // 在标签视图取消当前标签后，继续复核相邻的一张，避免选中状态丢失。
                if tagStore.flags(for:item.url,reviewing:true).contains(currentTag) {
                    if let index = items.firstIndex(where:{$0.url == item.url}) {
                        collection.reloadItems(at:[IndexPath(item:index,section:0)])
                        files.reloadData(forRowIndexes:IndexSet(integer:index),columnIndexes:IndexSet(integersIn:0..<files.numberOfColumns))
                    }
                } else {
                    let remaining = items.filter { tagStore.flags(for:$0.url,reviewing:true).contains(currentTag) }
                    selected = remaining.isEmpty ? nil : remaining[min(previousIndex,remaining.count-1)].url
                    allItems = tagStore.files(with:currentTag).map { MediaItem.read($0.url) }
                    filterItems()
                    if let index = items.firstIndex(where:{$0.url == selected}) { revealSelection(index) }
                }
            } else if let index = items.firstIndex(where:{$0.url == item.url}) {
                collection.reloadItems(at:[IndexPath(item:index,section:0)])
                files.reloadData(forRowIndexes:IndexSet(integer:index),columnIndexes:IndexSet(integersIn:0..<files.numberOfColumns))
            }
            status.stringValue = "\(adding ? "已添加" : "已取消")“\(tag.title)”标签 · \(items.count) 个文件"
        } catch { showError("标签未能保存",error:error) }
    }
    @objc func showBatchActions(_ sender: NSButton) {
        guard let menu = makeBatchMenu() else { return }
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.height),in:sender)
    }
    func makeBatchMenu() -> NSMenu? {
        guard !fileOperationRunning, let tag = currentTag else { return nil }
        let count = tagStore.files(with:tag).count
        let menu = NSMenu()
        let actions: [(String,Selector)] = tag == .chosen ? [("全部取消标签",#selector(clearChosenTags)),("全部复制到…",#selector(copyChosenFiles)),("全部移动到…",#selector(moveChosenFiles))] : [("确认删除…",#selector(confirmTrashFiles))]
        for (title,action) in actions { let item = menu.addItem(withTitle:"\(title)（\(count) 个）",action:action,keyEquivalent:""); item.target = self; item.isEnabled = count > 0 }
        menu.autoenablesItems = false; return menu
    }
    @objc func clearChosenTags() {
        guard !fileOperationRunning else { return }
        do { try tagStore.clear(.chosen); updateTagIndicators(); reloadCurrentSource(); status.stringValue = "已取消全部“已选择”标签，文件未改变。" }
        catch { showError("取消标签失败",error:error) }
    }
    @objc func copyChosenFiles() { chooseBatchDestination(.copy) }
    @objc func moveChosenFiles() { chooseBatchDestination(.move) }
    func chooseBatchDestination(_ action: FileBatchAction) {
        guard !fileOperationRunning else { return }
        let snapshot = tagStore.files(with:.chosen)
        guard !snapshot.isEmpty else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.title = "全部\(action.title)到"; panel.prompt = "\(action.title)到此目录"
        panel.message = "处理全部 \(snapshot.count) 个“已选择”文件，包含搜索未显示的项目。同名文件会自动加编号，不覆盖已有文件。"
        panel.directoryURL = folder
        panel.beginSheetModal(for:fullWindow ?? window!) { [weak self] response in
            guard let self = self, response == .OK, let destination = panel.url else { return }
            self.runFileBatch(action,files:snapshot,destination:destination)
        }
    }
    @objc func confirmTrashFiles() {
        guard !fileOperationRunning else { return }
        let snapshot = tagStore.files(with:.pendingDelete)
        guard !snapshot.isEmpty else { return }
        let alert = makeTrashConfirmation(snapshot)
        alert.beginSheetModal(for:fullWindow ?? window!) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.runFileBatch(.trash,files:snapshot,destination:nil)
        }
    }
    func makeTrashConfirmation(_ snapshot: [TaggedFile]) -> NSAlert {
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "将全部 \(snapshot.count) 个“待删除”文件移到废纸篓？"
        alert.informativeText = "包括其他目录及搜索未显示的标签文件。这里只移到系统废纸篓，不执行永久删除。不可用或身份不符的文件会跳过并保留标签。"
        alert.addButton(withTitle:"取消"); alert.addButton(withTitle:"移到废纸篓")
        alert.buttons[0].keyEquivalent = "\r"; alert.buttons[1].keyEquivalent = ""
        alert.window.defaultButtonCell = alert.buttons[0].cell as? NSButtonCell
        alert.accessoryView = batchDetails(snapshot.map { $0.url.path }.joined(separator:"\n"))
        return alert
    }
    func batchDetails(_ text: String) -> NSScrollView {
        let view = NSTextView(frame:NSRect(x:0,y:0,width:460,height:180)); view.string = text; view.isEditable = false; view.isRichText = false; view.font = .systemFont(ofSize:11)
        view.isVerticallyResizable = true; view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        let scroller = scroll(view); scroller.frame = NSRect(x:0,y:0,width:460,height:180); scroller.hasHorizontalScroller = false
        return scroller
    }
    func runFileBatch(_ action: FileBatchAction, files snapshot: [TaggedFile], destination: URL?) {
        guard !fileOperationRunning, !snapshot.isEmpty else { return }
        do { try tagStore.ensureWritable() } catch { showError("无法开始文件操作",error:error); return }
        fileOperationRunning = true; batchButton.isEnabled = false; video.player?.pause(); fullVideo.player?.pause()
        let reportsDirectory = tagStore.reportsDirectory
        status.stringValue = "正在\(action.title) \(snapshot.count) 个文件…"
        fileQueue.async {
            let result = Result { try FileBatchRunner.run(action:action,files:snapshot,destination:destination,reportsDirectory:reportsDirectory) { processed,total in
                DispatchQueue.main.async { self.status.stringValue = "正在\(action.title)：\(processed) / \(total)" }
            } }
            DispatchQueue.main.async {
                self.fileOperationRunning = false; self.batchButton.isEnabled = true
                switch result {
                case .failure(let error): self.showError("文件操作未开始",error:error)
                case .success(let value):
                    var report = value.0; let reportURL = value.1
                    var extra: [String] = []
                    do { try self.tagStore.apply(report); report.applied = true; try report.save(to:reportURL) }
                    catch { extra.append("文件操作结果已产生，但标签或日志保存失败。请保留结果日志，重启后会尝试恢复：\(error.localizedDescription)") }
                    if let error = report.journalError { extra.append(error) }
                    self.updateTagIndicators(); self.reloadCurrentSource()
                    let unprocessed = snapshot.count-report.successes.count-report.failures.count
                    let summary = "\(action.title)完成：成功 \(report.successes.count) 个，失败 \(report.failures.count) 个" + (unprocessed > 0 ? "，未处理 \(unprocessed) 个" : "")
                    self.status.stringValue = summary
                    let alert = NSAlert(); alert.messageText = summary
                    alert.informativeText = (extra + ["失败和未处理的文件保留原标签。完整结果保存在：\(reportURL.path)"]).joined(separator:"\n")
                    if !report.failures.isEmpty || !extra.isEmpty { alert.alertStyle = .warning; alert.accessoryView = self.batchDetails(report.failures.map { "\($0.source.path)\n\($0.message)" }.joined(separator:"\n\n")) }
                    alert.beginSheetModal(for:self.fullWindow ?? self.window!)
                }
            }
        }
    }
    func reloadCurrentSource() {
        if let tag = currentTag { showTag(tag,preferredSelection:selected) }
        else if let folder = folder { openFolder(folder,select:selected) }
    }
}
