import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var browser: BrowserController?
    private lazy var appIcon: NSImage? = Bundle.main.url(forResource:"LightLookLogo",withExtension:"png").flatMap { NSImage(contentsOf:$0) }
    private func refreshApplicationIcon() { if let icon = appIcon { NSApp.applicationIconImage = icon } }
    func applicationDidBecomeActive(_ notification: Notification) { refreshApplicationIcon() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 启动及激活时明确加载同一图标，避免系统沿用旧占位图。
        refreshApplicationIcon()
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem); let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle:"关于轻览",action:#selector(about),keyEquivalent:"").target = self
        appMenu.addItem(.separator()); appMenu.addItem(withTitle:"隐藏轻览",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h")
        appMenu.addItem(withTitle:"退出轻览",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let fileItem = NSMenuItem(); fileItem.title = "文件"; main.addItem(fileItem); let file = NSMenu(title:"文件"); fileItem.submenu = file
        file.addItem(withTitle:"打开文件夹…",action:#selector(openFolder),keyEquivalent:"o").target = self
        file.addItem(withTitle:"刷新",action:#selector(refresh),keyEquivalent:"r").target = self
        let editItem = NSMenuItem(); editItem.title = "编辑"; main.addItem(editItem); let edit = NSMenu(title:"编辑"); editItem.submenu = edit
        edit.addItem(withTitle:"剪切",action:#selector(NSText.cut(_:)),keyEquivalent:"x"); edit.addItem(withTitle:"复制",action:#selector(NSText.copy(_:)),keyEquivalent:"c"); edit.addItem(withTitle:"粘贴",action:#selector(NSText.paste(_:)),keyEquivalent:"v"); edit.addItem(withTitle:"全选",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
        let tagsItem = NSMenuItem(); tagsItem.title = "标签"; main.addItem(tagsItem)
        let tagsMenu = NSMenu(title:"标签"); tagsItem.submenu = tagsMenu
        tagsMenu.addItem(withTitle:"切换“已选择”标签（S）",action:#selector(chosenTag),keyEquivalent:"").target = self
        tagsMenu.addItem(withTitle:"切换“待删除”标签（D / Delete）",action:#selector(pendingTag),keyEquivalent:"").target = self
        let viewItem = NSMenuItem(); viewItem.title = "显示"; main.addItem(viewItem); let view = NSMenu(title:"显示"); viewItem.submenu = view
        view.addItem(withTitle:"元数据设置…",action:#selector(settings),keyEquivalent:",").target = self
        view.addItem(withTitle:"键盘操作说明",action:#selector(help),keyEquivalent:"?").target = self
        NSApp.mainMenu = main
        browser = browser ?? BrowserController(); browser?.showWindow(nil); NSApp.activate(ignoringOtherApps:true)
        let args = CommandLine.arguments
        if args.count > 1, !args[1].hasPrefix("-") {
            let url = URL(fileURLWithPath:args[1]); var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath:url.path,isDirectory:&directory) { browser?.openFolder(directory.boolValue ? url : url.deletingLastPathComponent(),select:directory.boolValue ? nil : url) }
        }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if browser == nil { browser = BrowserController(); browser?.showWindow(nil) }
        if let path = filenames.first { let url = URL(fileURLWithPath:path); browser?.openFolder(url.deletingLastPathComponent(),select:url) }
        sender.reply(toOpenOrPrint:.success)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if browser?.fileOperationRunning == true { browser?.status.stringValue = "文件批处理仍在进行，请等待完成后退出。"; NSSound.beep(); return .terminateCancel }
        return .terminateNow
    }
    @objc func chosenTag() { browser?.toggleChosenTag() }
    @objc func pendingTag() { browser?.togglePendingTag() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { browser?.locationPanel.shutdown(); browser?.castController.shutdown() }
    @objc func openFolder() { browser?.chooseFolder() }
    @objc func refresh() { browser?.refresh() }
    @objc func settings() { browser?.configureMetadata() }
    @objc func about() {
        var options: [NSApplication.AboutPanelOptionKey:Any] = [.applicationName:"轻览 LightLook",.applicationVersion:"0.2.0",.credits:NSAttributedString(string:"直接浏览文件夹的原生图片与视频查看器\nAppKit · Image I/O · AVKit · UPnP AV\n标签和设置保存在本机；删除仅移到废纸篓。")]
        if let icon = NSApp.applicationIconImage { options[.applicationIcon] = icon }
        NSApp.orderFrontStandardAboutPanel(options:options)
    }
    @objc func help() {
        let alert = NSAlert(); alert.messageText = "键盘与鼠标操作"; alert.informativeText = "空格：进入全屏；图片全屏时再次按空格返回\nEsc：退出全屏\n主窗口缩略图：左右键逐张，上下键按行浏览\n列表及全屏：方向键切换上一张 / 下一张\nS：切换“已选择”标签\nD / Delete：切换“待删除”标签（不会立即删除）\nF：全屏时切换 100% / 适应\n右下角元数据默认显示，可通过底部“显示元数据”开关隐藏\n全屏时按 1：100%（一个图像像素对应一个屏幕物理像素）\n全屏时按 0：适应窗口\n放大后方向键、滚动或鼠标拖动：平移图片\n⌥ + 方向键：放大时切换上一张 / 下一张\n双击全屏图片：切换 100% / 适应；双击缩略图：全屏\n视频全屏时空格：播放 / 暂停\n⌘O：打开目录；⌘R：刷新；⌘,：元数据设置"; alert.beginSheetModal(for:browser!.window!)
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
