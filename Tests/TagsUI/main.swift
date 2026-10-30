import AppKit
import ImageIO
import UniformTypeIdentifiers

func require(_ value: Bool,_ message: String) { if !value { fputs("FAIL: \(message)\n",stderr); exit(1) } }
func waitFor(_ message: String,_ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(8)
    while !predicate() {
        require(Date() < deadline,message)
        _ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.02))
    }
}
let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
let root = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true).appendingPathComponent("tag-ui-fixtures-\(UUID().uuidString)",isDirectory:true)
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:root) }
let photos = root.appendingPathComponent("photos",isDirectory:true)
try FileManager.default.createDirectory(at:photos,withIntermediateDirectories:true)
let context = CGContext(data:nil,width:32,height:32,bitsPerComponent:8,bytesPerRow:128,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(red:0.2,green:0.6,blue:0.8,alpha:1)); context.fill(CGRect(x:0,y:0,width:32,height:32))
for name in ["one.png","two.png","three.png"] {
    let destination = CGImageDestinationCreateWithURL(photos.appendingPathComponent(name) as CFURL,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(destination,context.makeImage()!,nil); require(CGImageDestinationFinalize(destination),"write PNG fixture")
}
let tags = FileTagStore(fileURL:root.appendingPathComponent("state/tags.json"))
let browser = BrowserController(tagStore:tags,restoreLastFolder:false)
browser.openFolder(photos)
waitFor("folder scan") { browser.items.count == 3 }
let first = browser.currentItem!.url
func key(_ code: UInt16,_ characters: String, window: NSWindow? = nil, repeated: Bool = false) {
    _ = browser.handleTagShortcut(code,isARepeat:repeated)
}
let windowless = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:-1,context:nil,characters:"s",charactersIgnoringModifiers:"s",isARepeat:false,keyCode:1)!
require(browser.key(windowless) != nil && tags.files(with:.chosen).isEmpty,"windowless key events cannot tag files")
key(1,"s")
require(tags.flags(for:first) == [.chosen],"main S shortcut adds chosen")
require(browser.chosenTagButton.title.contains("(1)"),"sidebar count updated")
key(1,"s",repeated:true)
require(tags.flags(for:first) == [.chosen],"holding key does not flicker tags")
let second = browser.items[1].url
browser.select(1); key(1,"s")
require(tags.files(with:.chosen).count == 2,"second photo chosen")
let full = NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:.titled,backing:.buffered,defer:false)
full.isReleasedWhenClosed = false; browser.fullWindow = full
key(2,"d",window:full)
require(tags.flags(for:second) == [.chosen,.pendingDelete],"full screen D shortcut tags same photo")
require(browser.fullTagLabel.stringValue.contains("已选择") && browser.fullTagLabel.stringValue.contains("待删除") && !browser.fullTagOverlay.isHidden,"full screen badges independent of metadata")
key(51,"\u{7f}",window:full)
require(tags.flags(for:second) == [.chosen],"Delete toggles pending off, does not trash")
key(117,"\u{7f}",window:full)
require(tags.flags(for:second) == [.chosen,.pendingDelete],"forward Delete toggles pending on")
require(FileManager.default.fileExists(atPath:second.path),"Delete shortcut never removes file")
let thumbnail = ThumbnailCell(); _ = thumbnail.view
thumbnail.configure(MediaItem.read(second),tags:tags.flags(for:second))
require(!thumbnail.tagsLabel.isHidden && thumbnail.tagsLabel.stringValue.contains("待删除"),"thumbnail tag overlay is visible")
browser.fileOperationRunning = true
key(1,"s",window:full)
require(tags.flags(for:second).contains(.chosen),"tags are locked during file batch")
browser.fileOperationRunning = false; browser.fullWindow = nil; full.close()
browser.showChosenTag()
waitFor("chosen review") { browser.items.count == 2 }
require(browser.currentTag == .chosen && browser.makeBatchMenu()?.items.count == 3,"chosen review offers exactly three actions")
require(browser.batchButton.isHidden == false,"batch button visible for tag review")
let reviewed = browser.currentItem!.url
key(1,"s")
require(browser.items.count == 1 && browser.currentItem?.url != reviewed,"untag in review advances to another photo")
browser.showPendingTag()
waitFor("pending review") { browser.items.count == 1 }
require(browser.currentTag == .pendingDelete && browser.makeBatchMenu()?.items.count == 1,"pending review offers only confirm-delete action")
let confirmation = browser.makeTrashConfirmation(tags.files(with:.pendingDelete))
require(confirmation.buttons.count == 2 && confirmation.buttons[0].title == "取消" && confirmation.buttons[1].title == "移到废纸篓","second confirmation defaults to cancel")
require(confirmation.buttons[0].keyEquivalent == "\r" && confirmation.buttons[1].keyEquivalent != "\r","Return cannot confirm destructive action")
require(confirmation.informativeText.contains("不执行永久删除"),"trash scope clear in confirmation")
key(2,"d")
require(browser.items.isEmpty && tags.files(with:.pendingDelete).isEmpty,"D untags pending review without deletion")
require(FileManager.default.fileExists(atPath:second.path),"review untagging preserves original")
if let monitor = browser.monitor { NSEvent.removeMonitor(monitor) }
browser.window?.delegate = nil; browser.locationPanel.shutdown(); browser.castController.shutdown(); browser.window?.close()
print("PASS controller S/D/Delete shortcuts, repeat protection, thumbnail/full badges, sidebar counts, review advance, three/one batch actions and second confirmation")
