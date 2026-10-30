import Foundation

func require(_ value: Bool,_ message: String) { if !value { fputs("FAIL: \(message)\n",stderr); exit(1) } }
func expectFailure(_ title: String,_ operation: () throws -> Void) { do { try operation(); require(false,title) } catch {} }
let fm = FileManager.default
let root = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true).appendingPathComponent("tag-fixtures-\(UUID().uuidString)",isDirectory:true)
try fm.createDirectory(at:root,withIntermediateDirectories:true)
defer { try? fm.removeItem(at:root) }
func folder(_ name: String) throws -> URL { let url = root.appendingPathComponent(name,isDirectory:true); try fm.createDirectory(at:url,withIntermediateDirectories:true); return url }
func file(_ name: String,_ contents: String = "photo bytes") throws -> URL { let url = root.appendingPathComponent(name); try Data(contents.utf8).write(to:url); return url }
func store(_ name: String) -> FileTagStore { FileTagStore(fileURL:root.appendingPathComponent(name+"/tags.json")) }

let a = try file("a.jpg"), b = try file("b.arw")
let tags = store("labels")
require(try tags.toggle(.chosen,url:a),"S adds chosen")
require(try tags.toggle(.pendingDelete,url:a),"D adds pending independently")
require(!(try tags.toggle(.chosen,url:a)),"second S removes chosen")
require(tags.flags(for:a) == [.pendingDelete],"other tag remains")
_ = try tags.toggle(.chosen,url:a); _ = try tags.toggle(.chosen,url:b)
let reloaded = FileTagStore(fileURL:tags.fileURL)
require(reloaded.files(with:.chosen).count == 2 && reloaded.flags(for:a).contains(.pendingDelete),"persistent tags across directories/restart")
try reloaded.clear(.chosen)
require(reloaded.files(with:.chosen).isEmpty && reloaded.flags(for:a) == [.pendingDelete],"clear chosen preserves pending")
require(try Data(contentsOf:a) == Data("photo bytes".utf8),"labels never modify source bytes")

let corrupt = root.appendingPathComponent("corrupt.json"); try Data("not valid json".utf8).write(to:corrupt)
let bad = FileTagStore(fileURL:corrupt)
require(bad.loadError != nil,"corrupt labels detected")
expectFailure("must not overwrite corrupt labels") { _ = try bad.toggle(.chosen,url:a) }
require(try String(contentsOf:corrupt,encoding:.utf8) == "not valid json","corrupt original preserved")
var refuseWrite = false
let guarded = FileTagStore(fileURL:root.appendingPathComponent("guarded.json"),writer:{ data,url in
    if refuseWrite { throw FileActionError.message("injected write failure") }; try data.write(to:url,options:.atomic)
})
_ = try guarded.toggle(.chosen,url:a); refuseWrite = true
expectFailure("toggle write failure") { _ = try guarded.toggle(.pendingDelete,url:a) }
require(guarded.flags(for:a) == [.chosen],"failed toggle is not applied in memory")
expectFailure("clear write failure") { try guarded.clear(.chosen) }
require(guarded.flags(for:a) == [.chosen],"failed clear retains old tags")

let copyStore = store("copy")
_ = try copyStore.toggle(.chosen,url:a)
let destination = try folder("copies"); let conflict = destination.appendingPathComponent(a.lastPathComponent)
try Data("existing destination".utf8).write(to:conflict)
let copyRecord = copyStore.record(for:a)!
let (copied,copyLog) = try FileBatchRunner.run(action:.copy,files:[copyRecord],destination:destination,reportsDirectory:copyStore.reportsDirectory)
require(copied.successes.count == 1 && copied.failures.isEmpty,"batch copy succeeds")
let copyURL = copied.successes[0].destination!
require(copyURL.lastPathComponent == "a (1).jpg","copy conflict auto-numbered")
require(try String(contentsOf:conflict,encoding:.utf8) == "existing destination","existing target not overwritten")
require(try FileBatchRunner.digest(a) == FileBatchRunner.digest(copyURL),"copy bytes verified")
try copyStore.apply(copied)
require(copyStore.flags(for:a) == [.chosen] && copyStore.record(for:copyURL) == nil,"copy retains original tag; new copy not tagged")
require(fm.fileExists(atPath:copyLog.path),"durable batch log")

let moveStore = store("move")
_ = try moveStore.toggle(.chosen,url:b); _ = try moveStore.toggle(.pendingDelete,url:b)
let movedFolder = try folder("moved")
try Data("keep".utf8).write(to:movedFolder.appendingPathComponent("b.arw"))
let oldRecord = moveStore.record(for:b)!
let (moved,_) = try FileBatchRunner.run(action:.move,files:[oldRecord],destination:movedFolder,reportsDirectory:moveStore.reportsDirectory)
require(moved.successes.count == 1 && moved.failures.isEmpty,"same-volume move succeeds")
let movedURL = moved.successes[0].destination!
require(!fm.fileExists(atPath:b.path) && movedURL.lastPathComponent == "b (1).arw","move original gone and target numbered")
let recovered = FileTagStore(fileURL:moveStore.fileURL)
require(try recovered.recoverBatches() == 1,"startup replays successful move log")
require(recovered.record(for:b) == nil && recovered.flags(for:movedURL) == [.chosen,.pendingDelete],"both tags follow moved file")
require(try recovered.recoverBatches() == 0,"journal replay is idempotent")
let sameFolderResult = try FileBatchRunner.perform(action:.move,file:recovered.record(for:movedURL)!,destination:movedFolder)
require(sameFolderResult.destination == movedURL,"move into original folder does not rename or remove")

let replaced = try file("replace-me.jpg","original")
let replaceStore = store("replacement")
_ = try replaceStore.toggle(.pendingDelete,url:replaced)
let recordBeforeReplacement = replaceStore.record(for:replaced)!
try fm.moveItem(at:replaced,to:root.appendingPathComponent("original-away.jpg"))
try Data("replacement must survive".utf8).write(to:replaced)
require(replaceStore.flags(for:replaced).isEmpty && replaceStore.flags(for:replaced,reviewing:true) == [.pendingDelete],"stale tag not applied to new file at same path")
let (rejected,_) = try FileBatchRunner.run(action:.trash,files:[recordBeforeReplacement],destination:nil,reportsDirectory:replaceStore.reportsDirectory)
require(rejected.successes.isEmpty && rejected.failures.count == 1,"replaced source not trashed")
require(try String(contentsOf:replaced,encoding:.utf8) == "replacement must survive","replacement preserved")
_ = try replaceStore.toggle(.pendingDelete,url:replaced,reviewing:true)
require(replaceStore.files(with:.pendingDelete).isEmpty,"stale review tag may be removed")

let link = root.appendingPathComponent("symlink.jpg")
try fm.createSymbolicLink(at:link,withDestinationURL:a)
expectFailure("symlinks cannot be tagged") { _ = try tags.toggle(.chosen,url:link) }
let partialStore = store("partial")
let available = try file("partial-ok.jpg"), unavailable = try file("partial-missing.jpg")
_ = try partialStore.toggle(.chosen,url:available); _ = try partialStore.toggle(.chosen,url:unavailable)
try fm.removeItem(at:unavailable)
let (partial,_) = try FileBatchRunner.run(action:.move,files:partialStore.files(with:.chosen),destination:try folder("partial-target"),reportsDirectory:partialStore.reportsDirectory)
require(partial.successes.count == 1 && partial.failures.count == 1,"partial failures reported independently")
try partialStore.apply(partial)
require(partialStore.record(for:unavailable)?.tags == [.chosen],"failed file retains tag")
let cannotLog = try file("not-a-journal-directory")
expectFailure("journal must be writable before changing files") { _ = try FileBatchRunner.run(action:.move,files:[copyRecord],destination:destination,reportsDirectory:cannotLog) }
require(fm.fileExists(atPath:a.path),"no file changed when journal creation fails")

// 仅将本测试创建的独立文件移到真实废纸篓，然后立即恢复，不触碰用户文件。
if CommandLine.arguments.contains("--trash") {
    let disposable = try file("lightlook-trash-test-\(UUID().uuidString).jpg","temporary trash test")
    let trashStore = store("trash")
    _ = try trashStore.toggle(.chosen,url:disposable); _ = try trashStore.toggle(.pendingDelete,url:disposable)
    let (trashed,_) = try FileBatchRunner.run(action:.trash,files:[trashStore.record(for:disposable)!],destination:nil,reportsDirectory:trashStore.reportsDirectory)
    require(trashed.successes.count == 1 && trashed.failures.isEmpty,"native system trash succeeds")
    guard let trashURL = trashed.successes.first?.destination else { require(false,"system trash returns recovery path"); exit(1) }
    require(!fm.fileExists(atPath:disposable.path) && fm.fileExists(atPath:trashURL.path),"trash is recoverable rather than permanent deletion")
    try trashStore.apply(trashed)
    require(trashStore.record(for:disposable) == nil,"successful trash removed from both tag lists")
    try fm.moveItem(at:trashURL,to:disposable)
    require(try String(contentsOf:disposable,encoding:.utf8) == "temporary trash test","disposable file recovered from system trash")
    print("PASS native Trash move and restoration of disposable fixture")
}
if let flag = CommandLine.arguments.firstIndex(of:"--cross-volume"), CommandLine.arguments.indices.contains(flag+1) {
    let volume = URL(fileURLWithPath:CommandLine.arguments[flag+1],isDirectory:true)
    let folder = volume.appendingPathComponent("lightlook-cross-\(UUID().uuidString)",isDirectory:true)
    try fm.createDirectory(at:folder,withIntermediateDirectories:false)
    defer { try? fm.removeItem(at:folder) }
    let cross = try file("cross-volume.jpg",String(repeating:"cross-volume\n",count:100000))
    let crossStore = store("cross-volume")
    _ = try crossStore.toggle(.chosen,url:cross)
    let digest = try FileBatchRunner.digest(cross)
    let (result,_) = try FileBatchRunner.run(action:.move,files:[crossStore.record(for:cross)!],destination:folder,reportsDirectory:crossStore.reportsDirectory)
    require(result.successes.count == 1 && result.failures.isEmpty,"cross-volume move succeeds")
    let output = result.successes[0].destination!
    require(try FileBatchRunner.digest(output) == digest && !fm.fileExists(atPath:cross.path),"cross-volume destination verified before removing source")
    try crossStore.apply(result)
    require(crossStore.flags(for:output) == [.chosen],"tag follows file to another volume")
    print("PASS real cross-volume copy/hash verification/move/tag relocation")
}
let collisionStore = store("stale-target-collision")
let collisionSourceFolder = try folder("collision-source")
let collisionDestinationFolder = try folder("collision-destination")
let collisionSource = collisionSourceFolder.appendingPathComponent("same.jpg")
let collisionDestination = collisionDestinationFolder.appendingPathComponent("same.jpg")
try Data("new chosen file".utf8).write(to:collisionSource)
try Data("old pending file".utf8).write(to:collisionDestination)
_ = try collisionStore.toggle(.chosen,url:collisionSource)
_ = try collisionStore.toggle(.pendingDelete,url:collisionDestination)
try fm.removeItem(at:collisionDestination)
let (collisionReport,_) = try FileBatchRunner.run(action:.move,files:[collisionStore.record(for:collisionSource)!],destination:collisionDestinationFolder,reportsDirectory:collisionStore.reportsDirectory)
require(collisionReport.successes.count == 1,"move to path with stale metadata succeeds physically")
expectFailure("stale record conflict handled without crash or tag inheritance") { try collisionStore.apply(collisionReport) }
require(collisionStore.flags(for:collisionDestination).isEmpty,"old pending tag never attached to new destination file")
_ = try collisionStore.toggle(.pendingDelete,url:collisionDestination,reviewing:true)
_ = try collisionStore.recoverBatches()
require(collisionStore.flags(for:collisionDestination) == [.chosen],"clearing stale target permits journal recovery")
print("PASS persistent tags, toggles, atomic saves, corruption/write protection, copy/move conflicts, journal recovery, partial failures and file identity protection")
