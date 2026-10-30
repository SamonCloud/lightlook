import AppKit
import AVKit

func label(_ text: String, size: CGFloat = 12, color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(labelWithString:text); field.font = .systemFont(ofSize:size); field.textColor = color; return field
}
func button(_ title: String, symbol: String? = nil, target: AnyObject?, action: Selector) -> NSButton {
    let b: NSButton
    if let symbol = symbol, let image = NSImage(systemSymbolName:symbol,accessibilityDescription:title) { b = NSButton(image:image,target:target,action:action); b.toolTip = title }
    else { b = NSButton(title:title,target:target,action:action) }
    b.bezelStyle = .rounded; return b
}
func scroll(_ document: NSView) -> NSScrollView {
    let view = NSScrollView(); view.documentView = document; view.hasVerticalScroller = true; view.autohidesScrollers = true; view.drawsBackground = false; return view
}

final class BrowserController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let tagStore: FileTagStore
    var currentTag: PhotoTag?
    let chosenTagButton = NSButton(title:"已选择",target:nil,action:nil)
    let pendingTagButton = NSButton(title:"待删除",target:nil,action:nil)
    let batchButton = NSButton(title:"批处理…",target:nil,action:nil)
    let fullTagOverlay = MetadataOverlayStack()
    let fullTagLabel = label("",size:13,color:.white)
    var fileOperationRunning = false
    let fileQueue = DispatchQueue(label:"lightlook.files",qos:.userInitiated)
    let outline = NSOutlineView()
    let collection = NSCollectionView()
    let files = NSTableView()
    let canvas = ImageCanvas()
    let video = AVPlayerView()
    let metadata = NSStackView()
    let locationPanel = PhotoLocationPanel(frame:.zero)
    let fileTitle = label("尚未选择文件",size:14)
    let status = label("打开文件夹，开始浏览",size:11,color:.secondaryLabelColor)
    let folderTitle = label("文件夹",size:12,color:.secondaryLabelColor)
    let pathLabel = label("轻览",size:12,color:.secondaryLabelColor)
    let search = NSSearchField()
    let mode = NSSegmentedControl(labels:["缩略图","列表"],trackingMode:.selectOne,target:nil,action:nil)
    let sort = NSPopUpButton()
    let thumbnailSize = NSSlider(value:170,minValue:110,maxValue:280,target:nil,action:nil)
    let central = NSView()
    var gridScroll: NSScrollView!
    var fileScroll: NSScrollView!
    var roots: [FolderNode] = []
    var allItems: [MediaItem] = []
    var items: [MediaItem] = []
    var selected: URL?
    var preferredGridX: CGFloat?
    var preferredGridWidth: CGFloat?
    var folder: URL?
    var fields = MetadataField.load()
    var currentMetadata: [String:String] = [:]
    var monitor: Any?
    var scanID = UUID()
    var previewID = UUID()
    let scanQueue = DispatchQueue(label:"lightlook.scan",qos:.userInitiated)
    let previewQueue = DispatchQueue(label:"lightlook.preview",qos:.userInitiated)
    var fullWindow: NSWindow?
    let fullCanvas = ImageCanvas()
    let fullVideo = AVPlayerView()
    let fullTitle = label("",size:13,color:.white)
    let fullMetadata = MetadataOverlayStack()
    lazy var fullMetadataWidth = fullMetadata.widthAnchor.constraint(equalToConstant:360)
    let fullMetadataSwitch = NSButton(checkboxWithTitle:"显示元数据",target:nil,action:nil)
    var showFullMetadata = UserDefaults.standard.object(forKey:"showFullscreenMetadata") as? Bool ?? true
    var previousPresentation: NSApplication.PresentationOptions = []
    let castController = CastController()
    var castBusy = false
    var settings: MetadataSettings?
    var retainedAlert: NSAlert?
    var fullImage: NSImage?
    var previewImage: NSImage?
    var currentItem: MediaItem? { items.first { $0.url == selected } }
    init(tagStore: FileTagStore? = nil, restoreLastFolder: Bool = true) {
        self.tagStore = tagStore ?? FileTagStore()
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:820),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        super.init(window:window)
        window.title = "轻览"; window.minSize = NSSize(width:960,height:620); window.setFrameAutosaveName("LightLookMain"); window.center(); window.delegate = self
        window.appearance = NSAppearance(named:.darkAqua)
        locationPanel.onResolved = { [weak self] in self?.renderMetadata() }
        buildUI(); buildRoots()
        canvas.allowsZoom = false; fullCanvas.requestZoom = { [weak self] actual in self?.setZoom(actual) }
        monitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in guard let self = self else { return event }; return self.key(event) }
        do { try self.tagStore.recoverBatches() } catch { DispatchQueue.main.async { self.showError("标签恢复未完成",error:error) } }
        updateTagIndicators()
        if let error = self.tagStore.loadError { DispatchQueue.main.async { self.showError("无法读取标签记录，原文件已保留",error:error) } }
        if restoreLastFolder, let path = UserDefaults.standard.string(forKey:"lastFolder"), FileManager.default.fileExists(atPath:path) { openFolder(URL(fileURLWithPath:path)) }
    }
    required init?(coder: NSCoder) { fatalError() }
    func buildUI() {
        guard let content = window?.contentView else { return }
        let outer = NSStackView(); outer.orientation = .vertical; outer.spacing = 0; outer.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(outer)
        NSLayoutConstraint.activate([outer.leadingAnchor.constraint(equalTo:content.leadingAnchor),outer.trailingAnchor.constraint(equalTo:content.trailingAnchor),outer.topAnchor.constraint(equalTo:content.topAnchor),outer.bottomAnchor.constraint(equalTo:content.bottomAnchor)])
        let top = NSStackView(); top.spacing = 10; top.edgeInsets = NSEdgeInsets(top:10,left:14,bottom:10,right:14)
        let open = button("打开文件夹",symbol:"folder.badge.plus",target:self,action:#selector(chooseFolder))
        let up = button("上一级目录",symbol:"arrow.up",target:self,action:#selector(parentFolder))
        let refresh = button("刷新",symbol:"arrow.clockwise",target:self,action:#selector(refresh))
        pathLabel.lineBreakMode = .byTruncatingHead; pathLabel.setContentHuggingPriority(.defaultLow,for:.horizontal)
        mode.selectedSegment = 0; mode.target = self; mode.action = #selector(switchBrowserMode)
        search.placeholderString = "搜索文件名"; search.delegate = self; search.widthAnchor.constraint(equalToConstant:180).isActive = true
        let cast = button("投屏到电视",symbol:"tv",target:self,action:#selector(showCasting))
        for v in [open,up,refresh,pathLabel,search,mode,cast] { top.addArrangedSubview(v) }
        outer.addArrangedSubview(top); top.widthAnchor.constraint(equalTo:outer.widthAnchor).isActive = true
        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin
        let left = NSStackView(); left.orientation = .vertical; left.alignment = .leading; left.spacing = 10; left.edgeInsets = NSEdgeInsets(top:12,left:10,bottom:8,right:8)
        left.addArrangedSubview(label("目录",size:11,color:.secondaryLabelColor))
        let column = NSTableColumn(identifier:.init("folder")); column.title = "目录"; outline.addTableColumn(column); outline.outlineTableColumn = column; outline.headerView = nil; outline.rowHeight = 28; outline.indentationPerLevel = 13; outline.dataSource = self; outline.delegate = self; outline.backgroundColor = .clear
        let treeScroll = scroll(outline); left.addArrangedSubview(treeScroll); treeScroll.widthAnchor.constraint(equalTo:left.widthAnchor,constant:-18).isActive = true
        treeScroll.heightAnchor.constraint(greaterThanOrEqualToConstant:120).isActive = true
        treeScroll.setContentHuggingPriority(.defaultLow,for:.vertical)
        left.addArrangedSubview(label("标签",size:11,color:.secondaryLabelColor))
        for (tagButton,action) in [(chosenTagButton,#selector(showChosenTag)),(pendingTagButton,#selector(showPendingTag))] {
            tagButton.bezelStyle = .recessed; tagButton.setButtonType(.pushOnPushOff); tagButton.alignment = .left
            tagButton.target = self; tagButton.action = action; left.addArrangedSubview(tagButton)
            tagButton.widthAnchor.constraint(equalTo:left.widthAnchor,constant:-18).isActive = true
        }
        left.widthAnchor.constraint(greaterThanOrEqualToConstant:170).isActive = true; left.widthAnchor.constraint(lessThanOrEqualToConstant:360).isActive = true
        let middle = NSStackView(); middle.orientation = .vertical; middle.spacing = 0
        let middleTop = NSStackView(); middleTop.edgeInsets = NSEdgeInsets(top:10,left:16,bottom:10,right:12); middleTop.spacing = 12
        folderTitle.setContentHuggingPriority(.defaultLow,for:.horizontal); folderTitle.lineBreakMode = .byTruncatingMiddle
        sort.addItems(withTitles:["文件名 ↑","文件名 ↓","修改时间 ↓","文件大小 ↓"]); sort.target = self; sort.action = #selector(filterItems)
        thumbnailSize.target = self; thumbnailSize.action = #selector(changeSize); thumbnailSize.widthAnchor.constraint(equalToConstant:85).isActive = true; thumbnailSize.toolTip = "缩略图大小"
        batchButton.bezelStyle = .rounded; batchButton.target = self; batchButton.action = #selector(showBatchActions(_:)); batchButton.isHidden = true
        for v in [folderTitle,batchButton,sort,thumbnailSize] { middleTop.addArrangedSubview(v) }
        middle.addArrangedSubview(middleTop); middleTop.widthAnchor.constraint(equalTo:middle.widthAnchor).isActive = true
        let layout = NSCollectionViewFlowLayout(); layout.itemSize = NSSize(width:170,height:175); layout.minimumInteritemSpacing = 10; layout.minimumLineSpacing = 10; layout.sectionInset = NSEdgeInsets(top:12,left:14,bottom:14,right:14)
        collection.collectionViewLayout = layout; collection.isSelectable = true; collection.allowsMultipleSelection = false; collection.backgroundColors = [NSColor(calibratedWhite:0.11,alpha:1)]; collection.dataSource = self; collection.delegate = self; collection.register(ThumbnailCell.self,forItemWithIdentifier:.init("thumbnail"))
        let doubleClick = NSClickGestureRecognizer(target:self,action:#selector(openFullscreen)); doubleClick.numberOfClicksRequired = 2; collection.addGestureRecognizer(doubleClick)
        gridScroll = scroll(collection)
        for (id,title,width) in [("name","文件名",280.0),("tags","标签",140.0),("type","格式",70.0),("size","大小",95.0),("modified","修改时间",155.0)] {
            let c = NSTableColumn(identifier:.init(id)); c.title = title; c.width = width; files.addTableColumn(c)
        }
        files.rowHeight = 29; files.usesAlternatingRowBackgroundColors = true; files.delegate = self; files.dataSource = self; files.target = self; files.doubleAction = #selector(openFullscreen); files.allowsMultipleSelection = false
        fileScroll = scroll(files); fileScroll.hasHorizontalScroller = true; fileScroll.isHidden = true
        middle.addArrangedSubview(central); central.widthAnchor.constraint(equalTo:middle.widthAnchor).isActive = true
        for v in [gridScroll!,fileScroll!] { central.addSubview(v); v.translatesAutoresizingMaskIntoConstraints = false; NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo:central.topAnchor),v.bottomAnchor.constraint(equalTo:central.bottomAnchor),v.leadingAnchor.constraint(equalTo:central.leadingAnchor),v.trailingAnchor.constraint(equalTo:central.trailingAnchor)]) }
        middle.widthAnchor.constraint(greaterThanOrEqualToConstant:380).isActive = true
        let right = NSStackView(); right.orientation = .vertical; right.spacing = 12; right.edgeInsets = NSEdgeInsets(top:14,left:14,bottom:12,right:14)
        let previewHeader = NSStackView(); previewHeader.addArrangedSubview(label("预览",size:11,color:.secondaryLabelColor)); previewHeader.addArrangedSubview(NSView()); previewHeader.addArrangedSubview(button("全屏查看（空格）",symbol:"arrow.up.left.and.arrow.down.right",target:self,action:#selector(openFullscreen)))
        right.addArrangedSubview(previewHeader)
        let previewBox = NSView(); right.addArrangedSubview(previewBox); previewBox.heightAnchor.constraint(equalToConstant:225).isActive = true
        for v in [canvas,video] { previewBox.addSubview(v); v.translatesAutoresizingMaskIntoConstraints = false; NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo:previewBox.leadingAnchor),v.trailingAnchor.constraint(equalTo:previewBox.trailingAnchor),v.topAnchor.constraint(equalTo:previewBox.topAnchor),v.bottomAnchor.constraint(equalTo:previewBox.bottomAnchor)]) }
        video.isHidden = true; video.controlsStyle = .inline
        fileTitle.lineBreakMode = .byTruncatingMiddle; right.addArrangedSubview(fileTitle)
        let metaHeader = NSStackView(); metaHeader.addArrangedSubview(label("元数据",size:11,color:.secondaryLabelColor)); metaHeader.addArrangedSubview(NSView()); metaHeader.addArrangedSubview(button("自定义元数据",symbol:"slider.horizontal.3",target:self,action:#selector(configureMetadata))); right.addArrangedSubview(metaHeader)
        metadata.orientation = .vertical; metadata.alignment = .leading; metadata.spacing = 11; metadata.edgeInsets = NSEdgeInsets(top:4,left:0,bottom:12,right:6)
        let metaScroll = scroll(metadata); right.addArrangedSubview(metaScroll)
        metadata.translatesAutoresizingMaskIntoConstraints = false; metadata.widthAnchor.constraint(equalTo:metaScroll.contentView.widthAnchor).isActive = true
        for v in [previewHeader,previewBox,fileTitle,metaHeader,metaScroll] { v.widthAnchor.constraint(equalTo:right.widthAnchor,constant:-28).isActive = true }
        right.widthAnchor.constraint(greaterThanOrEqualToConstant:280).isActive = true; right.widthAnchor.constraint(lessThanOrEqualToConstant:430).isActive = true
        split.addArrangedSubview(left); split.addArrangedSubview(middle); split.addArrangedSubview(right)
        outer.addArrangedSubview(split); split.widthAnchor.constraint(equalTo:outer.widthAnchor).isActive = true
        let bottom = NSStackView(); bottom.edgeInsets = NSEdgeInsets(top:8,left:14,bottom:8,right:14); bottom.addArrangedSubview(status); bottom.addArrangedSubview(NSView()); bottom.addArrangedSubview(label("空格 全屏  ·  方向键 浏览",size:11,color:.secondaryLabelColor)); outer.addArrangedSubview(bottom); bottom.widthAnchor.constraint(equalTo:outer.widthAnchor).isActive = true
        split.setPosition(205,ofDividerAt:0); split.setPosition(925,ofDividerAt:1)
        renderMetadata()
    }
    func buildRoots() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var urls = [home.appendingPathComponent("Pictures"),home.appendingPathComponent("Desktop"),home.appendingPathComponent("Downloads"),home,URL(fileURLWithPath:"/Volumes")]
        if let folder = folder, !urls.contains(folder) { urls.insert(folder,at:0) }
        roots = urls.filter { FileManager.default.fileExists(atPath:$0.path) }.map(FolderNode.init); outline.reloadData()
    }
    @objc func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "打开"; panel.directoryURL = folder
        panel.beginSheetModal(for:window!) { [weak self] response in if response == .OK, let url = panel.url { self?.openFolder(url) } }
    }
    @objc func parentFolder() { if let folder = folder { openFolder(currentTag == nil ? folder.deletingLastPathComponent() : folder) } }
    @objc func refresh() { buildRoots(); do { try tagStore.recoverBatches() } catch { showError("标签恢复失败",error:error) }; reloadCurrentSource() }
    func openFolder(_ url: URL, select: URL? = nil) {
        currentTag = nil; updateTagIndicators()
        let token = UUID(); scanID = token; status.stringValue = "正在读取目录…"; folder = url; pathLabel.stringValue = url.path; pathLabel.toolTip = url.path; folderTitle.stringValue = url.lastPathComponent
        scanQueue.async {
            let result = Result { try MediaItem.scan(url) }
            DispatchQueue.main.async {
                guard self.scanID == token else { return }
                switch result {
                case .success(let items):
                    self.allItems = items; self.selected = select ?? items.first?.url; self.filterItems(); UserDefaults.standard.set(url.path,forKey:"lastFolder"); self.window?.representedURL = url; self.window?.makeFirstResponder(self.mode.selectedSegment == 0 ? self.collection : self.files)
                case .failure(let error): self.allItems = []; self.selected = nil; self.filterItems(); self.showError("无法读取文件夹",error:error)
                }
            }
        }
    }
    @objc func filterItems() {
        let old = selected
        preferredGridX = nil
        items = allItems.filter { search.stringValue.isEmpty || $0.name.localizedCaseInsensitiveContains(search.stringValue) }
        switch sort.indexOfSelectedItem {
        case 1: items.sort { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case 2: items.sort { $0.modified == $1.modified ? $0.name < $1.name : $0.modified > $1.modified }
        case 3: items.sort { $0.size == $1.size ? $0.name < $1.name : $0.size > $1.size }
        default: items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        MediaLoader.shared.clearPending(); collection.reloadData(); files.reloadData()
        selected = items.contains(where:{$0.url == old}) ? old : items.first?.url
        syncSelection(); loadSelection()
        status.stringValue = (currentTag.map { "\($0.title) · " } ?? "") + "\(items.count) 个文件" + (items.count != allItems.count ? " / 共 \(allItems.count) 个" : "")
        updateTagIndicators()
    }
    func controlTextDidChange(_ obj: Notification) { filterItems() }
    @objc func switchBrowserMode() { preferredGridX = nil; gridScroll.isHidden = mode.selectedSegment == 1; fileScroll.isHidden = mode.selectedSegment == 0; thumbnailSize.isHidden = mode.selectedSegment == 1; syncSelection(); if let index = items.firstIndex(where:{$0.url == selected}) { revealSelection(index) }; window?.makeFirstResponder(mode.selectedSegment == 0 ? collection : files) }
    @objc func changeSize() { preferredGridX = nil; if let layout = collection.collectionViewLayout as? NSCollectionViewFlowLayout { let n = CGFloat(thumbnailSize.doubleValue); layout.itemSize = NSSize(width:n,height:n+5); layout.invalidateLayout() } }
    func syncSelection() {
        guard let index = items.firstIndex(where:{$0.url == selected}) else { collection.selectionIndexPaths = []; files.deselectAll(nil); return }
        collection.selectionIndexPaths = [IndexPath(item:index,section:0)]; files.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false)
    }
    func select(_ index: Int, preservingGridColumn: Bool = false) {
        guard items.indices.contains(index), selected != items[index].url else { return }
        if !preservingGridColumn { preferredGridX = nil }
        selected = items[index].url; syncSelection(); loadSelection()
    }
    func navigate(_ step: Int) {
        preferredGridX = nil
        guard let index = items.firstIndex(where:{$0.url == selected}), !items.isEmpty else { return }
        let next = min(items.count-1,max(0,index+step)); select(next)
        revealSelection(next)
    }
    func navigateGridRow(_ direction: Int) {
        guard let current = items.firstIndex(where:{$0.url == selected}), let layout = collection.collectionViewLayout else { return }
        collection.layoutSubtreeIfNeeded()
        let width = collection.bounds.width
        if let previous = preferredGridWidth, abs(previous-width) > 0.5 { preferredGridX = nil }
        preferredGridWidth = width
        guard let destination = GridRowNavigation.destination(current:current,count:items.count,direction:direction,preferredX:preferredGridX,frameAt:{ layout.layoutAttributesForItem(at:IndexPath(item:$0,section:0))?.frame }) else { return }
        preferredGridX = destination.preferredX
        select(destination.index,preservingGridColumn:true)
        revealSelection(destination.index)
    }
    func revealSelection(_ index: Int) {
        guard items.indices.contains(index) else { return }
        if mode.selectedSegment == 1 { files.scrollRowToVisible(index); return }
        if !CollectionSelectionVisibility.reveal(index:index,collection:collection,scrollView:gridScroll) {
            // 目录刷新或重新排版尚未结束时，在下一次主线程布局后再定位一次。
            let url = items[index].url
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.mode.selectedSegment == 0, self.selected == url,
                      self.items.indices.contains(index), self.items[index].url == url else { return }
                CollectionSelectionVisibility.reveal(index:index,collection:self.collection,scrollView:self.gridScroll)
            }
        }
    }
    func loadSelection() {
        let token = UUID(); previewID = token; fullImage = nil; previewImage = nil
        canvas.image = nil; fullCanvas.image = nil; canvas.actualSize = false; fullCanvas.actualSize = false
        video.player?.pause(); fullVideo.player?.pause(); video.player = nil; fullVideo.player = nil
        currentMetadata = [:]; locationPanel.update(raw:nil); renderMetadata()
        guard let item = currentItem else { fileTitle.stringValue = "尚未选择文件"; canvas.isHidden = false; video.isHidden = true; canvas.message = items.isEmpty ? "此目录没有匹配的图片或视频" : "选择一张图片"; if fullWindow != nil { closeFullscreen() }; return }
        fileTitle.stringValue = item.name; fileTitle.toolTip = item.url.path; fullTitle.stringValue = item.name
        updateTagIndicators()
        if !isFileAvailable(item) {
            canvas.isHidden = false; video.isHidden = true; fullCanvas.isHidden = false; fullVideo.isHidden = true
            canvas.message = "文件不可用或已被替换"; fullCanvas.message = "文件不可用或已被替换 · 可取消标签或按 Esc 返回"
            currentMetadata = ["path":item.url.path]; renderMetadata(); return
        }
        canvas.isHidden = item.isVideo; video.isHidden = !item.isVideo; fullCanvas.isHidden = item.isVideo; fullVideo.isHidden = !item.isVideo
        if item.isVideo {
            let player = AVPlayer(url:item.url); player.preventsDisplaySleepDuringVideoPlayback = true
            if fullWindow != nil { fullVideo.player = player; player.play() } else { video.player = player }
        } else {
            canvas.message = "正在读取图片…"; fullCanvas.message = "正在读取图片…"
            let pixels = max(2560, Int(NSScreen.screens.map { max($0.frame.width,$0.frame.height) * $0.backingScaleFactor }.max() ?? 2560))
            previewQueue.async {
                let image = autoreleasepool { MediaLoader.decode(item.url,pixels:pixels).map { NSImage(cgImage:$0,size:NSSize(width:$0.width,height:$0.height)) } }
                DispatchQueue.main.async {
                    guard self.previewID == token else { return }
                    self.previewImage = image
                    if !self.canvas.actualSize { self.canvas.image = image }
                    if !self.fullCanvas.actualSize { self.fullCanvas.image = image }
                    if image == nil { self.canvas.message = "系统无法解码此文件"; self.fullCanvas.message = "系统无法解码此文件 · 可按 Esc 返回"; self.status.stringValue = "无法解码 \(item.name)，请检查相机机型是否受系统支持。" }
                }
            }
        }
        previewQueue.async {
            let values = MediaLoader.metadata(item)
            DispatchQueue.main.async { guard self.previewID == token else { return }; self.currentMetadata = values; self.locationPanel.update(raw:values["location"]); self.renderMetadata() }
        }
    }
    func renderMetadata() {
        for v in metadata.arrangedSubviews { metadata.removeArrangedSubview(v); v.removeFromSuperview() }
        for field in fields where field.visible {
            let row = NSStackView(); row.alignment = .firstBaseline; row.spacing = 8
            let title = label(field.title,size:11,color:.secondaryLabelColor); title.widthAnchor.constraint(equalToConstant:64).isActive = true
            let value = label(metadataValue(field.id),size:11); value.isSelectable = true; value.lineBreakMode = .byWordWrapping; value.maximumNumberOfLines = 3; value.toolTip = currentMetadata[field.id]
            row.addArrangedSubview(title); row.addArrangedSubview(value); metadata.addArrangedSubview(row); row.widthAnchor.constraint(equalTo:metadata.widthAnchor,constant:-6).isActive = true
        }
        metadata.addArrangedSubview(locationPanel)
        locationPanel.widthAnchor.constraint(equalTo:metadata.widthAnchor,constant:-6).isActive = true
        renderFullscreenMetadata()
    }
    func metadataValue(_ id: String) -> String {
        if id == "location", let description = locationPanel.resolvedDescription, let raw = currentMetadata[id] { return "\(description)\n\(raw)" }
        return currentMetadata[id] ?? "—"
    }
    func renderFullscreenMetadata() {
        for view in fullMetadata.arrangedSubviews { fullMetadata.removeArrangedSubview(view); view.removeFromSuperview() }
        fullMetadata.isHidden = !showFullMetadata || currentItem == nil || currentItem?.isVideo == true
        fullMetadataSwitch.state = showFullMetadata ? .on : .off
        fullMetadataSwitch.isEnabled = currentItem?.isVideo != true
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.9); shadow.shadowBlurRadius = 3; shadow.shadowOffset = NSSize(width:0,height:-1)
        for field in fields where field.visible {
            let row = label("",size:11)
            row.alignment = .right; row.lineBreakMode = .byTruncatingMiddle
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .right; paragraph.lineBreakMode = .byTruncatingMiddle
            row.attributedStringValue = NSAttributedString(string:"\(field.title)  \(metadataValue(field.id).replacingOccurrences(of:"\n",with:" · "))",attributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:NSColor.white.withAlphaComponent(0.72),.shadow:shadow,.paragraphStyle:paragraph])
            fullMetadata.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo:fullMetadata.widthAnchor).isActive = true
        }
    }
    @objc func toggleFullscreenMetadata(_ sender: NSButton) {
        showFullMetadata = sender.state == .on
        UserDefaults.standard.set(showFullMetadata,forKey:"showFullscreenMetadata")
        renderFullscreenMetadata()
    }
    @objc func configureMetadata() {
        settings = MetadataSettings(fields:fields) { [weak self] fields in self?.fields = fields; MetadataField.save(fields); self?.renderMetadata() }
        window?.beginSheet(settings!.panel)
    }
    @objc func openFullscreen() {
        guard fullWindow == nil, let item = currentItem, let screen = window?.screen ?? NSScreen.main else { return }
        let w = FullscreenWindow(contentRect:screen.frame,styleMask:[.borderless],backing:.buffered,defer:false); w.title = "轻览 · 全屏"; w.backgroundColor = .black; w.isReleasedWhenClosed = false; w.collectionBehavior = [.fullScreenAuxiliary]; w.appearance = NSAppearance(named:.darkAqua)
        let content = NSView(frame:NSRect(origin:.zero,size:screen.frame.size)); w.contentView = content
        for v in [fullCanvas,fullVideo] { v.frame = content.bounds; v.autoresizingMask = [.width,.height]; content.addSubview(v) }
        fullTagOverlay.orientation = .horizontal; fullTagOverlay.edgeInsets = NSEdgeInsets(top:6,left:10,bottom:6,right:10)
        fullTagOverlay.wantsLayer = true; fullTagOverlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor; fullTagOverlay.layer?.cornerRadius = 6
        if fullTagLabel.superview == nil { fullTagOverlay.addArrangedSubview(fullTagLabel) }
        fullTagOverlay.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(fullTagOverlay)
        NSLayoutConstraint.activate([fullTagOverlay.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:24),fullTagOverlay.topAnchor.constraint(equalTo:content.topAnchor,constant:24),fullTagOverlay.trailingAnchor.constraint(lessThanOrEqualTo:content.trailingAnchor,constant:-24)])
        updateTagIndicators()
        fullVideo.controlsStyle = .floating; fullCanvas.isHidden = item.isVideo; fullVideo.isHidden = !item.isVideo
        fullCanvas.image = previewImage; fullCanvas.actualSize = false; canvas.actualSize = false; canvas.image = previewImage
        fullTitle.stringValue = item.name; fullTitle.lineBreakMode = .byTruncatingMiddle
        fullTitle.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        fullMetadata.orientation = .vertical; fullMetadata.alignment = .trailing; fullMetadata.spacing = 3
        fullMetadata.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(fullMetadata)
        fullMetadataWidth.constant = min(360,screen.frame.width*0.30)
        NSLayoutConstraint.activate([fullMetadata.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-24),fullMetadata.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-88),fullMetadataWidth,fullMetadata.topAnchor.constraint(greaterThanOrEqualTo:content.topAnchor,constant:24)])
        fullMetadataSwitch.target = self; fullMetadataSwitch.action = #selector(toggleFullscreenMetadata(_:))
        fullMetadataSwitch.toolTip = "显示或隐藏右下角元数据；字段内容与顺序沿用元数据设置"
        renderFullscreenMetadata()
        let bar = NSStackView(); bar.wantsLayer = true; bar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor; bar.layer?.cornerRadius = 10; bar.spacing = 14; bar.edgeInsets = NSEdgeInsets(top:10,left:16,bottom:10,right:16)
        for v in [button("返回",symbol:"xmark",target:self,action:#selector(closeFullscreen)),button("上一张",symbol:"chevron.left",target:self,action:#selector(previous)),fullTitle,button("下一张",symbol:"chevron.right",target:self,action:#selector(next)),button("100% / 适应（F）",target:self,action:#selector(toggleZoom)),fullMetadataSwitch] { bar.addArrangedSubview(v) }
        bar.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(bar)
        NSLayoutConstraint.activate([bar.centerXAnchor.constraint(equalTo:content.centerXAnchor),bar.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-28),bar.widthAnchor.constraint(lessThanOrEqualTo:content.widthAnchor,constant:-50),fullTitle.widthAnchor.constraint(lessThanOrEqualToConstant:320)])
        fullWindow = w; previousPresentation = NSApp.presentationOptions; NSApp.presentationOptions = [.autoHideDock,.autoHideMenuBar]; w.makeKeyAndOrderFront(nil); w.makeFirstResponder(fullCanvas)
        if item.isVideo { fullVideo.player = video.player; video.player = nil }
    }
    @objc func closeFullscreen() {
        guard let w = fullWindow else { return }
        if currentItem?.isVideo == true { video.player = fullVideo.player; fullVideo.player = nil }
        w.orderOut(nil); w.close(); fullWindow = nil; fullCanvas.image = nil; fullImage = nil; NSApp.presentationOptions = previousPresentation; window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(mode.selectedSegment == 0 ? collection : files)
    }
    @objc func next() { navigate(1) }
    @objc func previous() { navigate(-1) }
    @objc func toggleZoom() { setZoom(!fullCanvas.actualSize) }
    func setZoom(_ actual: Bool) {
        guard fullWindow != nil, let item = currentItem, !item.isVideo else { return }
        let target = fullCanvas
        target.actualSize = actual
        if !actual { target.image = previewImage; return }
        if let image = fullImage { target.image = image; return }
        target.message = "正在读取原尺寸图片…"
        let token = previewID
        previewQueue.async {
            let image = MediaLoader.decode(item.url,pixels:100000).map { NSImage(cgImage:$0,size:NSSize(width:$0.width,height:$0.height)) }
            DispatchQueue.main.async {
                guard self.previewID == token, self.fullWindow != nil else { return }
                self.fullImage = image
                let target = self.fullCanvas
                if target.actualSize { target.image = image; if image == nil { target.message = "无法读取原尺寸图片" } }
            }
        }
    }
    func key(_ event: NSEvent) -> NSEvent? {
        guard let eventWindow = event.window, eventWindow === window || eventWindow === fullWindow else { return event }
        if window?.attachedSheet != nil || fullWindow?.attachedSheet != nil { return event }
        if event.window?.firstResponder is NSTextView { return event }
        let command = event.modifierFlags.contains(.command)
        if command { return event }
        if !event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.control) && [UInt16(1),2,51,117].contains(event.keyCode) {
            if fullWindow == nil && eventWindow.firstResponder === outline { return event }
            if handleTagShortcut(event.keyCode,isARepeat:event.isARepeat) { return nil }
        }
        switch event.keyCode {
        case 3:
            if fullWindow != nil && currentItem?.isVideo == false && !event.modifierFlags.contains(.control) && !event.modifierFlags.contains(.option) {
                if !event.isARepeat { toggleZoom() }; return nil
            }
        case 49: if fullWindow == nil { openFullscreen() } else if currentItem?.isVideo == true { if let p = fullVideo.player { p.rate == 0 ? p.play() : p.pause() } } else { closeFullscreen() }; return nil
        case 53: if fullWindow != nil { closeFullscreen(); return nil }
        case 18,83: if fullWindow != nil { setZoom(true); return nil }
        case 29,82: if fullWindow != nil { setZoom(false); return nil }
        case 123,124,125,126:
            if fullWindow == nil && mode.selectedSegment == 0 && (event.keyCode == 125 || event.keyCode == 126) {
                navigateGridRow(event.keyCode == 126 ? -1 : 1); return nil
            }
            let target = fullWindow != nil ? fullCanvas : canvas
            if target.actualSize && !event.modifierFlags.contains(.option) && currentItem?.isVideo != true {
                switch event.keyCode { case 123: target.pan(80,0); case 124: target.pan(-80,0); case 125: target.pan(0,-80); default: target.pan(0,80) }
            } else { navigate(event.keyCode == 123 || event.keyCode == 126 ? -1 : 1) }
            return nil
        default: break
        }
        return event
    }
    func showError(_ title: String,error: Error) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = error.localizedDescription; alert.beginSheetModal(for:fullWindow ?? window!)
    }
    @objc func showCasting() {
        let menu = NSMenu(); menu.addItem(withTitle:"搜索 DLNA 电视…",action:#selector(discoverTV),keyEquivalent:"").target = self
        menu.addItem(withTitle:"输入设备描述地址…",action:#selector(manualTV),keyEquivalent:"").target = self
        menu.addItem(withTitle:"停止投屏并关闭共享",action:#selector(stopCasting),keyEquivalent:"").target = self
        menu.popUp(positioning:nil,at:NSEvent.mouseLocation,in:nil)
    }
    @objc func discoverTV() {
        guard !castBusy else { return }; castBusy = true; status.stringValue = "正在搜索同一局域网的 DLNA 电视…"
        castController.discover { devices in
            self.castBusy = false
            guard !devices.isEmpty else { self.status.stringValue = "未发现 DLNA 电视"; self.showError("未发现可投屏设备",error:CastError.message("请确认电视已开启 DLNA / 媒体接收功能，且电脑与电视在同一局域网。部分电视只支持 AirPlay 或 Chromecast，不支持 DLNA。也可以输入设备描述 XML 地址连接。")); return }
            let alert = NSAlert(); alert.messageText = "投屏到电视"; alert.informativeText = "图片将生成最大边 3840 像素的 JPEG；MP4 将直接传输。电视将通过局域网读取当前所选媒体。"; alert.addButton(withTitle:"播放"); alert.addButton(withTitle:"取消")
            let popup = NSPopUpButton(frame:NSRect(x:0,y:0,width:360,height:28)); popup.addItems(withTitles:devices.map(\.name)); alert.accessoryView = popup
            alert.beginSheetModal(for:self.window!) { response in if response == .alertFirstButtonReturn { self.cast(to:devices[popup.indexOfSelectedItem]) } }
        }
    }
    @objc func manualTV() {
        let alert = NSAlert(); alert.messageText = "连接 DLNA 设备"; alert.informativeText = "输入电视的 UPnP 设备描述 XML 地址，例如 http://192.168.1.10:端口/description.xml。此地址由电视提供。"; alert.addButton(withTitle:"连接"); alert.addButton(withTitle:"取消")
        let field = NSTextField(frame:NSRect(x:0,y:0,width:380,height:26)); field.placeholderString = "http://…/description.xml"; alert.accessoryView = field
        alert.beginSheetModal(for:window!) { response in
            guard response == .alertFirstButtonReturn else { return }
            guard let url = URL(string:field.stringValue), ["http","https"].contains(url.scheme ?? ""), url.host != nil else { self.showError("地址无效",error:CastError.message("请输入完整的 HTTP 或 HTTPS 设备描述地址。")); return }
            self.castController.resolve(url) { device in DispatchQueue.main.async { if let device = device { self.cast(to:device) } else { self.showError("连接失败",error:CastError.message("设备描述中没有找到可用的 AVTransport 服务。")) } } }
        }
    }
    func cast(to device: Renderer) {
        guard let item = currentItem else { return }; guard !castBusy else { return }; castBusy = true; status.stringValue = "正在投屏到 \(device.name)…"
        castController.cast(item,to:device) { error in
            self.castBusy = false
            if let error = error { self.castController.server.stop(); self.showError("投屏失败",error:error); self.status.stringValue = "投屏失败" }
            else { self.status.stringValue = "正在投屏：\(item.name) → \(device.name)；切换文件后需再次点击投屏。" }
        }
    }
    @objc func stopCasting() { castController.stop { error in if let error = error { self.showError("停止投屏失败",error:error) } else { self.status.stringValue = "已停止投屏，局域网媒体共享已关闭。" } } }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if fileOperationRunning { status.stringValue = "文件批处理仍在进行，请等待完成后退出。"; NSSound.beep(); return false }; return true
    }
    func windowDidResize(_ notification: Notification) { preferredGridX = nil }
    func windowWillClose(_ notification: Notification) { closeFullscreen(); if let monitor = monitor { NSEvent.removeMonitor(monitor) }; locationPanel.shutdown(); castController.shutdown(); NSApp.terminate(nil) }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }; let item = items[row]; let text: String
        switch column?.identifier.rawValue { case "tags": text = PhotoTag.text(flags(for:item.url)); case "type": text = item.url.pathExtension.uppercased(); case "size": text = ByteCountFormatter.string(fromByteCount:item.size,countStyle:.file); case "modified": text = DateFormatter.localizedString(from:item.modified,dateStyle:.short,timeStyle:.short); default: text = (item.isVideo ? "▶  " : "") + item.name }
        let field = label(text,size:12); field.lineBreakMode = .byTruncatingMiddle; field.toolTip = column?.identifier.rawValue == "name" ? item.url.path : text; return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) { if files.selectedRow >= 0 { select(files.selectedRow) } }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier:.init("thumbnail"),for:indexPath) as! ThumbnailCell; let item = items[indexPath.item]; cell.configure(item,tags:flags(for:item.url),available:isFileAvailable(item)); return cell
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { if let index = indexPaths.first?.item { select(index) } }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? FolderNode)?.load().count ?? roots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { if let node = item as? FolderNode { return node.load()[index] }; return roots[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { true }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FolderNode else { return nil }
        let cell = NSTableCellView(); let icon = NSImageView(); icon.image = NSImage(systemSymbolName:node.url.path == "/Volumes" ? "externaldrive" : "folder",accessibilityDescription:nil); icon.contentTintColor = .secondaryLabelColor
        let text = label(node.url.lastPathComponent,size:12); text.lineBreakMode = .byTruncatingMiddle; cell.toolTip = node.url.path
        for v in [icon,text] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
        NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:2),icon.centerYAnchor.constraint(equalTo:cell.centerYAnchor),icon.widthAnchor.constraint(equalToConstant:16),icon.heightAnchor.constraint(equalToConstant:16),text.leadingAnchor.constraint(equalTo:icon.trailingAnchor,constant:7),text.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-3),text.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) { if let node = outline.item(atRow:outline.selectedRow) as? FolderNode { openFolder(node.url) } }
}
