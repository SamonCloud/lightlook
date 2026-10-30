import Foundation
import Darwin

enum PhotoTag: String, Codable, CaseIterable {
    case chosen, pendingDelete
    var title: String { self == .chosen ? "已选择" : "待删除" }
    var marker: String { self == .chosen ? "✓ 已选择" : "待删除" }
    static func text(_ tags: Set<PhotoTag>) -> String { allCases.filter { tags.contains($0) }.map(\.marker).joined(separator:" · ") }
}

enum FileActionError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct TaggedFileIdentity: Codable, Equatable {
    let inode: UInt64
    let birthSeconds: Int64
    let birthNanos: Int64
    let volume: String
    static func capture(_ url: URL) throws -> TaggedFileIdentity {
        var info = stat()
        guard lstat(url.path,&info) == 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw FileActionError.message("只支持普通文件；不会处理文件夹或符号链接。") }
        let uuid = try? url.resourceValues(forKeys:[.volumeUUIDStringKey]).volumeUUIDString
        // 网络卷可能没有 UUID，此时保留其挂载路径，不主动挂载已离线的卷。
        let volume = uuid ?? (url.path.hasPrefix("/Volumes/") ? url.pathComponents.prefix(3).joined(separator:"/") : "local")
        return .init(inode:UInt64(info.st_ino),birthSeconds:Int64(info.st_birthtimespec.tv_sec),birthNanos:Int64(info.st_birthtimespec.tv_nsec),volume:volume)
    }
}

struct TaggedFile: Codable, Equatable {
    let id: UUID
    var url: URL
    var identity: TaggedFileIdentity
    var tags: Set<PhotoTag>
    var isAvailable: Bool { (try? TaggedFileIdentity.capture(url)) == identity }
}

final class FileTagStore {
    struct Document: Codable { var version = 1; var files: [TaggedFile] }
    let fileURL: URL
    let reportsDirectory: URL
    private(set) var records: [UUID:TaggedFile] = [:]
    private var paths: [String:UUID] = [:]
    private(set) var loadError: Error?
    private(set) var persistenceError: Error?
    private let writer: (Data,URL) throws -> Void
    init(fileURL: URL? = nil, writer: ((Data,URL) throws -> Void)? = nil) {
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!.appendingPathComponent("LightLook",isDirectory:true)
        self.fileURL = fileURL ?? support.appendingPathComponent("tags.json")
        reportsDirectory = self.fileURL.deletingLastPathComponent().appendingPathComponent("Batches",isDirectory:true)
        self.writer = writer ?? { data,url in try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true); try data.write(to:url,options:.atomic) }
        if FileManager.default.fileExists(atPath:self.fileURL.path) {
            do {
                let document = try JSONDecoder().decode(Document.self,from:Data(contentsOf:self.fileURL))
                guard document.version == 1 else { throw FileActionError.message("标签文件版本不受支持，原文件已保留。") }
                for var record in document.files where !record.tags.isEmpty {
                    record.url = record.url.standardizedFileURL
                    guard records[record.id] == nil, !records.values.contains(where:{$0.url == record.url}) else { throw FileActionError.message("标签记录重复，原文件已保留。") }
                    records[record.id] = record
                }
                rebuildIndex()
            } catch { records = [:]; paths = [:]; loadError = error }
        }
    }
    private func rebuildIndex() { paths = Dictionary(uniqueKeysWithValues:records.values.map { ($0.url.standardizedFileURL.path,$0.id) }) }
    func record(for url: URL) -> TaggedFile? { paths[url.standardizedFileURL.path].flatMap { records[$0] } }
    func flags(for url: URL, reviewing: Bool = false) -> Set<PhotoTag> {
        guard let record = record(for:url), reviewing || record.isAvailable else { return [] }; return record.tags
    }
    func files(with tag: PhotoTag) -> [TaggedFile] {
        records.values.filter { $0.tags.contains(tag) }.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }
    private func persist(_ next: [UUID:TaggedFile]) throws {
        if let error = loadError { throw FileActionError.message("无法读取原标签文件，已停止写入以保护记录：\(error.localizedDescription)") }
        let data = try JSONEncoder().encode(Document(files:next.values.sorted { $0.id.uuidString < $1.id.uuidString }))
        try writer(data,fileURL)
    }
    func ensureWritable() throws { try persist(records); persistenceError = nil }
    @discardableResult
    func toggle(_ tag: PhotoTag, url: URL, reviewing: Bool = false) throws -> Bool {
        let url = url.standardizedFileURL
        var next = records
        var record: TaggedFile
        if let existing = self.record(for:url) {
            guard existing.isAvailable || (reviewing && existing.tags.contains(tag)) else { throw FileActionError.message("该文件不可用或已被替换。请在标签列表中取消旧标签后再标记；不会操作替换后的文件。") }
            record = existing
        } else { record = TaggedFile(id:UUID(),url:url,identity:try TaggedFileIdentity.capture(url),tags:[]) }
        let adding = !record.tags.contains(tag)
        if adding { record.tags.insert(tag) } else { record.tags.remove(tag) }
        if record.tags.isEmpty { next.removeValue(forKey:record.id) } else { next[record.id] = record }
        try persist(next); records = next; rebuildIndex(); persistenceError = nil
        return adding
    }
    func clear(_ tag: PhotoTag) throws {
        var next = records
        for id in Array(next.keys) {
            next[id]?.tags.remove(tag)
            if next[id]?.tags.isEmpty == true { next.removeValue(forKey:id) }
        }
        try persist(next); records = next; rebuildIndex(); persistenceError = nil
    }
    func apply(_ report: FileBatchReport) throws {
        var next = records
        for success in report.successes {
            guard var record = next[success.recordID], record.url == success.source, record.identity == success.sourceIdentity else { continue }
            switch report.action {
            case .copy: continue
            case .move:
                guard let target = success.destination, let identity = success.destinationIdentity else { continue }
                record.url = target; record.identity = identity; next[record.id] = record
            case .trash: next.removeValue(forKey:record.id)
            }
        }
        guard Set(next.values.map { $0.url.standardizedFileURL.path }).count == next.count else {
            throw FileActionError.message("目标路径已有失效的旧标签记录。请先在标签列表取消该路径的旧标签，再刷新恢复本次结果；成功文件的操作日志已保留。")
        }
        // 文件已发生变化时，即使磁盘写失败，也保留正确的内存状态；批处理日志供下次启动恢复。
        records = next; rebuildIndex()
        do { try persist(next); persistenceError = nil }
        catch { persistenceError = error; throw error }
    }
    @discardableResult
    func recoverBatches() throws -> Int {
        guard loadError == nil else { return 0 }
        let urls = (try? FileManager.default.contentsOfDirectory(at:reportsDirectory,includingPropertiesForKeys:nil)) ?? []
        var count = 0
        for url in urls.sorted(by:{$0.lastPathComponent < $1.lastPathComponent}) where url.pathExtension == "json" {
            var report = try JSONDecoder().decode(FileBatchReport.self,from:Data(contentsOf:url))
            guard !report.applied else { continue }
            try apply(report); report.applied = true; try report.save(to:url); count += report.successes.count
        }
        return count
    }
}
