import Foundation
import CryptoKit
import Darwin

enum FileBatchAction: String, Codable {
    case copy, move, trash
    var title: String { switch self { case .copy:return "复制"; case .move:return "移动"; case .trash:return "移到废纸篓" } }
}
struct FileBatchSuccess: Codable {
    let recordID: UUID
    let source: URL
    let sourceIdentity: TaggedFileIdentity
    let destination: URL?
    let destinationIdentity: TaggedFileIdentity?
}
struct FileBatchFailure: Codable { let source: URL; let message: String }
struct FileBatchReport: Codable {
    let id: UUID
    let date: Date
    let action: FileBatchAction
    let files: [TaggedFile]
    let destination: URL?
    var successes: [FileBatchSuccess] = []
    var failures: [FileBatchFailure] = []
    var finished = false
    var applied = false
    var journalError: String?
    func save(to url: URL) throws { try JSONEncoder().encode(self).write(to:url,options:.atomic) }
}

struct FileBatchRunner {
    struct Snapshot: Equatable {
        let identity: TaggedFileIdentity
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanos: Int64
        static func capture(_ url: URL) throws -> Snapshot {
            let identity = try TaggedFileIdentity.capture(url)
            var info = stat(); guard lstat(url.path,&info) == 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
            return .init(identity:identity,size:Int64(info.st_size),modifiedSeconds:Int64(info.st_mtimespec.tv_sec),modifiedNanos:Int64(info.st_mtimespec.tv_nsec))
        }
    }
    static func run(action: FileBatchAction, files: [TaggedFile], destination: URL?, reportsDirectory: URL, progress: ((Int,Int)->Void)? = nil) throws -> (FileBatchReport,URL) {
        let fm = FileManager.default
        try fm.createDirectory(at:reportsDirectory,withIntermediateDirectories:true)
        var report = FileBatchReport(id:UUID(),date:Date(),action:action,files:files,destination:destination)
        let reportURL = reportsDirectory.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(report.id.uuidString).json")
        // 日志必须先能写入，才开始变更文件。
        try report.save(to:reportURL)
        for (index,file) in files.enumerated() {
            do { report.successes.append(try perform(action:action,file:file,destination:destination)) }
            catch { report.failures.append(.init(source:file.url,message:error.localizedDescription)) }
            do { try report.save(to:reportURL) }
            catch { report.journalError = "结果日志保存失败：\(error.localizedDescription)"; break }
            progress?(index+1,files.count)
        }
        report.finished = report.successes.count+report.failures.count == files.count
        do { try report.save(to:reportURL) } catch { report.journalError = "结果日志保存失败：\(error.localizedDescription)" }
        return (report,reportURL)
    }
    static func perform(action: FileBatchAction, file: TaggedFile, destination: URL?) throws -> FileBatchSuccess {
        let fm = FileManager.default
        let snapshot = try Snapshot.capture(file.url)
        guard snapshot.identity == file.identity else { throw FileActionError.message("源文件已被替换；为保护文件，未执行操作。") }
        if action == .trash {
            var result: NSURL?
            try fm.trashItem(at:file.url,resultingItemURL:&result)
            return .init(recordID:file.id,source:file.url,sourceIdentity:file.identity,destination:result as URL?,destinationIdentity:nil)
        }
        guard let destination = destination else { throw FileActionError.message("没有选择目标文件夹。") }
        var directory: ObjCBool = false
        guard fm.fileExists(atPath:destination.path,isDirectory:&directory), directory.boolValue else { throw FileActionError.message("目标文件夹不可用，原文件未改变。") }
        if action == .move && file.url.deletingLastPathComponent().resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() {
            return .init(recordID:file.id,source:file.url,sourceIdentity:file.identity,destination:file.url,destinationIdentity:file.identity)
        }
        if action == .move {
            var counter = 0
            while counter < 10000 {
                let target = candidate(for:file.url,in:destination,counter:counter)
                if renamex_np(file.url.path,target.path,UInt32(RENAME_EXCL)) == 0 {
                    return .init(recordID:file.id,source:file.url,sourceIdentity:file.identity,destination:target,destinationIdentity:file.identity)
                }
                let code = errno
                if code == EEXIST { counter += 1; continue }
                if code == EXDEV { break }
                throw NSError(domain:NSPOSIXErrorDomain,code:Int(code))
            }
            if counter >= 10000 { throw FileActionError.message("同名文件过多，未移动源文件。") }
        }
        // 复制及跨卷移动：先复制到目标卷的独立暂存目录，逐块校验，再以不覆盖方式发布。
        let stageDirectory = destination.appendingPathComponent(".lightlook-\(UUID().uuidString)",isDirectory:true)
        try fm.createDirectory(at:stageDirectory,withIntermediateDirectories:false)
        defer { try? fm.removeItem(at:stageDirectory) }
        let staged = stageDirectory.appendingPathComponent(file.url.lastPathComponent)
        try fm.copyItem(at:file.url,to:staged)
        let sourceHash = try digest(file.url); let copyHash = try digest(staged)
        guard sourceHash == copyHash, try Snapshot.capture(file.url) == snapshot else { throw FileActionError.message("复制校验失败或源文件在操作中发生变化；原文件已保留。") }
        var published: URL?
        for counter in 0..<10000 {
            let target = candidate(for:file.url,in:destination,counter:counter)
            if renamex_np(staged.path,target.path,UInt32(RENAME_EXCL)) == 0 { published = target; break }
            if errno != EEXIST { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
        }
        guard let target = published else { throw FileActionError.message("同名文件过多，原文件已保留。") }
        let targetIdentity = try TaggedFileIdentity.capture(target)
        if action == .move {
            guard try Snapshot.capture(file.url) == snapshot else { throw FileActionError.message("源文件已变化；保留原文件及目标副本：\(target.path)") }
            do { try fm.removeItem(at:file.url) }
            catch { throw FileActionError.message("目标副本已保存，但原文件未能移除，原标签保留：\(target.path)；\(error.localizedDescription)") }
        }
        return .init(recordID:file.id,source:file.url,sourceIdentity:file.identity,destination:target,destinationIdentity:targetIdentity)
    }
    private static func candidate(for source: URL,in folder: URL,counter: Int) -> URL {
        guard counter > 0 else { return folder.appendingPathComponent(source.lastPathComponent) }
        let ext = source.pathExtension
        let name = source.deletingPathExtension().lastPathComponent + " (\(counter))" + (ext.isEmpty ? "" : ".\(ext)")
        return folder.appendingPathComponent(name)
    }
    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom:url); defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount:524288), !data.isEmpty { hasher.update(data:data) }
        return hasher.finalize().map { String(format:"%02x",$0) }.joined()
    }
}
