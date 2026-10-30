import Foundation
import Network
import Darwin
import ImageIO
import UniformTypeIdentifiers

struct Renderer: Hashable {
    let name: String
    let controlURL: URL
    let service: String
}

enum CastError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct ByteRange: Equatable {
    let start: Int64
    let end: Int64
    static func parse(_ value: String?, size: Int64) throws -> ByteRange {
        guard size > 0 else { throw CastError.message("空文件") }
        guard let value = value else { return ByteRange(start:0,end:size-1) }
        guard value.lowercased().hasPrefix("bytes="), !value.contains(",") else { throw CastError.message("无效 Range") }
        let parts = value.dropFirst(6).split(separator:"-",omittingEmptySubsequences:false)
        guard parts.count == 2 else { throw CastError.message("无效 Range") }
        if parts[0].isEmpty {
            guard let tail = Int64(parts[1]), tail > 0 else { throw CastError.message("无效 Range") }
            return ByteRange(start:max(0,size-tail),end:size-1)
        }
        guard let start = Int64(parts[0]), start >= 0, start < size else { throw CastError.message("超出范围") }
        let end: Int64
        if parts[1].isEmpty { end = size-1 } else {
            guard let parsed = Int64(parts[1]), parsed >= start else { throw CastError.message("无效 Range") }; end = min(parsed,size-1)
        }
        return ByteRange(start:start,end:end)
    }
}

final class MediaHTTPServer {
    private let queue = DispatchQueue(label:"lightlook.http")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier:NWConnection] = [:]
    private var awaitingHeaders = Set<ObjectIdentifier>()
    private var current: (path:String,url:URL,mime:String)?
    var port: UInt16 { listener?.port?.rawValue ?? 0 }
    func start(completion: @escaping (Result<UInt16,Error>) -> Void) {
        queue.async { [self] in
            if let listener = self.listener, let port = listener.port { DispatchQueue.main.async { completion(.success(port.rawValue)) }; return }
            do {
                let listener = try NWListener(using:.tcp,on:.any); self.listener = listener
                var delivered = false
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: if !delivered { delivered = true; DispatchQueue.main.async { completion(.success(listener.port!.rawValue)) } }
                    case .failed(let error): if !delivered { delivered = true; DispatchQueue.main.async { completion(.failure(error)) } }; listener.cancel(); self.listener = nil
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self = self else { return }
                    guard self.connections.count < 12 else { connection.cancel(); return }
                    self.connections[ObjectIdentifier(connection)] = connection
                    self.awaitingHeaders.insert(ObjectIdentifier(connection))
                    connection.stateUpdateHandler = { [weak self, weak connection] state in
                        if case .failed = state, let connection = connection { self?.connections.removeValue(forKey:ObjectIdentifier(connection)); self?.awaitingHeaders.remove(ObjectIdentifier(connection)); connection.cancel() }
                        if case .cancelled = state, let connection = connection { self?.connections.removeValue(forKey:ObjectIdentifier(connection)); self?.awaitingHeaders.remove(ObjectIdentifier(connection)) }
                    }
                    connection.start(queue:self.queue); self.receive(connection,buffer:Data())
                    self.queue.asyncAfter(deadline:.now()+15) { [weak self, weak connection] in
                        if let connection = connection, self?.awaitingHeaders.contains(ObjectIdentifier(connection)) == true { connection.cancel() }
                    }
                }
                listener.start(queue:self.queue)
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }
    func expose(url: URL, mime: String) -> String {
        let path = "/\(UUID().uuidString)/media.\(mime == "image/jpeg" ? "jpg" : "mp4")"
        queue.sync { current = (path,url,mime) }
        return path
    }
    func stop() {
        queue.async { self.listener?.stateUpdateHandler = nil; self.listener?.newConnectionHandler = nil; self.listener?.cancel(); self.listener = nil; self.current = nil; for c in self.connections.values { c.cancel() }; self.connections.removeAll(); self.awaitingHeaders.removeAll() }
    }
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:8192) { data, _, finished, error in
            var buffer = buffer; if let data = data { buffer.append(data) }
            guard buffer.count <= 32768 else { connection.cancel(); return }
            if let text = String(data:buffer,encoding:.utf8), text.contains("\r\n\r\n") { self.respond(connection,text:text) }
            else if finished || error != nil { connection.cancel() }
            else { self.receive(connection,buffer:buffer) }
        }
    }
    private func respond(_ connection: NWConnection, text: String) {
        awaitingHeaders.remove(ObjectIdentifier(connection))
        let lines = text.components(separatedBy:"\r\n")
        let first = (lines.first ?? "").split(separator:" ")
        guard first.count == 3 else { connection.cancel(); return }
        let method = String(first[0])
        guard method == "GET" || method == "HEAD" else { sendError(connection,code:"405 Method Not Allowed"); return }
        guard let current = current, first[1] == Substring(current.path), let attrs = try? FileManager.default.attributesOfItem(atPath:current.url.path), let number = attrs[.size] as? NSNumber else { sendError(connection,code:"404 Not Found"); return }
        let size = number.int64Value
        var headers: [String:String] = [:]
        for line in lines.dropFirst() { if let colon = line.firstIndex(of:":") { headers[String(line[..<colon]).lowercased()] = line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces) } }
        let range: ByteRange
        do { range = try ByteRange.parse(headers["range"],size:size) }
        catch { sendError(connection,code:"416 Range Not Satisfiable",extra:"Content-Range: bytes */\(size)\r\n"); return }
        let partial = headers["range"] != nil
        var response = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\nContent-Type: \(current.mime)\r\nContent-Length: \(range.end-range.start+1)\r\nAccept-Ranges: bytes\r\nConnection: close\r\ntransferMode.dlna.org: \(current.mime.hasPrefix("image/") ? "Interactive" : "Streaming")\r\ncontentFeatures.dlna.org: DLNA.ORG_OP=01;DLNA.ORG_CI=0\r\n"
        if partial { response += "Content-Range: bytes \(range.start)-\(range.end)/\(size)\r\n" }
        response += "\r\n"
        guard method != "HEAD" else { connection.send(content:response.data(using:.utf8),completion:.contentProcessed { _ in connection.cancel() }); return }
        guard let handle = try? FileHandle(forReadingFrom:current.url), (try? handle.seek(toOffset:UInt64(range.start))) != nil else { sendError(connection,code:"500 Internal Server Error"); return }
        connection.send(content:response.data(using:.utf8),completion:.contentProcessed { error in
            if error != nil { try? handle.close(); connection.cancel(); return }
            self.stream(connection,handle:handle,remaining:range.end-range.start+1)
        })
    }
    private func stream(_ connection: NWConnection, handle: FileHandle, remaining: Int64) {
        guard remaining > 0 else { try? handle.close(); connection.cancel(); return }
        guard let data = try? handle.read(upToCount:Int(min(262144,remaining))), !data.isEmpty else { try? handle.close(); connection.cancel(); return }
        connection.send(content:data,completion:.contentProcessed { error in
            if error != nil { try? handle.close(); connection.cancel(); return }
            self.stream(connection,handle:handle,remaining:remaining-Int64(data.count))
        })
    }
    private func sendError(_ connection: NWConnection, code: String, extra: String = "") {
        connection.send(content:"HTTP/1.1 \(code)\r\n\(extra)Content-Length: 0\r\nConnection: close\r\n\r\n".data(using:.utf8),completion:.contentProcessed { _ in connection.cancel() })
    }
}

final class CastController {
    let server = MediaHTTPServer()
    private let queue = DispatchQueue(label:"lightlook.cast",qos:.userInitiated)
    private var tempURL: URL?
    var active: Renderer?
    var session = URLSession(configuration: {
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 12; return config
    }())
    static func xml(_ value: String) -> String { value.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;").replacingOccurrences(of:"'",with:"&apos;") }
    static func multicastInterfaces() -> [in_addr] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0 else { return [] }; defer { freeifaddrs(pointer) }
        var result: [in_addr] = []; var cursor = pointer
        while let current = cursor {
            let item = current.pointee
            if let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), item.ifa_flags & UInt32(IFF_UP) != 0, item.ifa_flags & UInt32(IFF_MULTICAST) != 0, item.ifa_flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) == 0 {
                result.append(UnsafeRawPointer(address).assumingMemoryBound(to:sockaddr_in.self).pointee.sin_addr)
            }
            cursor = item.ifa_next
        }
        return result
    }
    func discover(completion: @escaping ([Renderer]) -> Void) {
        queue.async {
            let fd = socket(AF_INET,SOCK_DGRAM,IPPROTO_UDP)
            guard fd >= 0 else { DispatchQueue.main.async { completion([]) }; return }; defer { close(fd) }
            var bindAddress = sockaddr_in(); bindAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); bindAddress.sin_family = sa_family_t(AF_INET)
            _ = withUnsafePointer(to:&bindAddress) { a in a.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            var loop: UInt8 = 1; setsockopt(fd,IPPROTO_IP,IP_MULTICAST_LOOP,&loop,socklen_t(MemoryLayout<UInt8>.size))
            var addr = sockaddr_in(); addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = UInt16(1900).bigEndian; inet_pton(AF_INET,"239.255.255.250",&addr.sin_addr)
            let request = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n"
            var interfaces = Self.multicastInterfaces()
            if interfaces.isEmpty { interfaces = [in_addr(s_addr:INADDR_ANY)] }
            for var interface in interfaces {
                setsockopt(fd,IPPROTO_IP,IP_MULTICAST_IF,&interface,socklen_t(MemoryLayout<in_addr>.size))
                for _ in 0..<2 { request.withCString { p in withUnsafePointer(to:&addr) { a in a.withMemoryRebound(to:sockaddr.self,capacity:1) { _ = sendto(fd,p,strlen(p),0,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } } } }
            }
            let deadline = Date().addingTimeInterval(4)
            var locations = Set<URL>()
            while Date() < deadline {
                var pollFD = pollfd(fd:fd,events:Int16(POLLIN),revents:0)
                if poll(&pollFD,1,200) > 0 {
                    var buffer = [UInt8](repeating:0,count:8192)
                    let count = recv(fd,&buffer,buffer.count,0)
                    if count > 0, let text = String(bytes:buffer.prefix(count),encoding:.utf8) {
                        for line in text.components(separatedBy:"\r\n") where line.lowercased().hasPrefix("location:") {
                            if let url = URL(string:String(line.dropFirst(9)).trimmingCharacters(in:.whitespaces)), ["http","https"].contains(url.scheme?.lowercased() ?? "") { locations.insert(url) }
                        }
                    }
                }
            }
            let group = DispatchGroup(); let lock = NSLock(); var devices: [Renderer] = []
            for location in locations.prefix(32) {
                group.enter(); self.resolve(location) { renderer in
                    lock.lock(); if let renderer = renderer, !devices.contains(renderer) { devices.append(renderer) }; lock.unlock(); group.leave()
                }
            }
            group.wait(); DispatchQueue.main.async { completion(devices.sorted { $0.name < $1.name }) }
        }
    }
    func resolve(_ location: URL, completion: @escaping (Renderer?) -> Void) {
        session.dataTask(with:location) { data, response, _ in
            guard let response = response as? HTTPURLResponse, response.statusCode == 200, let data = data, data.count < 2_000_000, let doc = try? XMLDocument(data:data,options:[.nodeLoadExternalEntitiesNever]) else { completion(nil); return }
            let baseText = (try? doc.nodes(forXPath:"//*[local-name()='URLBase']").first?.stringValue) ?? nil
            let base = baseText.flatMap(URL.init(string:)) ?? location
            let services = (try? doc.nodes(forXPath:"//*[local-name()='service']")) ?? []
            for node in services {
                let type = (try? node.nodes(forXPath:"./*[local-name()='serviceType']").first?.stringValue) ?? nil
                let path = (try? node.nodes(forXPath:"./*[local-name()='controlURL']").first?.stringValue) ?? nil
                if let type = type, type.contains(":AVTransport:"), let path = path, let url = URL(string:path,relativeTo:base)?.absoluteURL, ["http","https"].contains(url.scheme ?? "") {
                    let name = (try? node.nodes(forXPath:"../..//*[local-name()='friendlyName']").first?.stringValue) ?? "电视"
                    completion(Renderer(name:name,controlURL:url,service:type)); return
                }
            }
            completion(nil)
        }.resume()
    }
    func action(_ device: Renderer, name: String, values: [(String,String)], completion: @escaping (Error?) -> Void) {
        let body = values.map { "<\($0.0)>\(Self.xml($0.1))</\($0.0)>" }.joined()
        let xml = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(name) xmlns:u=\"\(device.service)\">\(body)</u:\(name)></s:Body></s:Envelope>"
        var request = URLRequest(url:device.controlURL); request.httpMethod = "POST"; request.httpBody = xml.data(using:.utf8)
        request.setValue("text/xml; charset=\"utf-8\"",forHTTPHeaderField:"Content-Type"); request.setValue("\"\(device.service)#\(name)\"",forHTTPHeaderField:"SOAPACTION")
        session.dataTask(with:request) { data,response,error in
            if let error = error { completion(error); return }
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                var detail = "电视拒绝执行 \(name)"
                if let data = data, let doc = try? XMLDocument(data:data,options:[.nodeLoadExternalEntitiesNever]), let description = try? doc.nodes(forXPath:"//*[local-name()='errorDescription']").first?.stringValue { detail += "：\(description)" }
                completion(CastError.message(detail)); return
            }
            completion(nil)
        }.resume()
    }
    static func localAddress(for host: String, port: UInt16) -> String? {
        var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_DGRAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host,String(port),&hints,&list) == 0, let info = list else { return nil }; defer { freeaddrinfo(info) }
        let fd = socket(AF_INET,SOCK_DGRAM,0); guard fd >= 0 else { return nil }; defer { close(fd) }
        guard Darwin.connect(fd,info.pointee.ai_addr,info.pointee.ai_addrlen) == 0 else { return nil }
        var local = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to:&local) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { getsockname(fd,$0,&length) } }
        guard ok == 0 else { return nil }
        var buffer = [CChar](repeating:0,count:Int(INET_ADDRSTRLEN)); inet_ntop(AF_INET,&local.sin_addr,&buffer,socklen_t(INET_ADDRSTRLEN)); return String(cString:buffer)
    }
    func cast(_ item: MediaItem, to device: Renderer, completion: @escaping (Error?) -> Void) {
        queue.async {
            do {
                let file: URL; let mime: String
                if item.isVideo { file = item.url; mime = "video/mp4"; if item.url.pathExtension.lowercased() == "mov" { throw CastError.message("DLNA 暂支持 MP4/M4V 视频；MOV 可在本机播放。") } }
                else {
                    guard let image = MediaLoader.decode(item.url,pixels:3840) else { throw CastError.message("此文件无法生成投屏图片。") }
                    file = FileManager.default.temporaryDirectory.appendingPathComponent("lightlook-cast-\(UUID().uuidString).jpg"); mime = "image/jpeg"
                    guard let dest = CGImageDestinationCreateWithURL(file as CFURL,UTType.jpeg.identifier as CFString,1,nil) else { throw CastError.message("无法建立投屏临时文件。") }
                    CGImageDestinationAddImage(dest,image,[kCGImageDestinationLossyCompressionQuality:0.92] as CFDictionary)
                    guard CGImageDestinationFinalize(dest) else { throw CastError.message("无法生成投屏图片。") }
                    if let old = self.tempURL { try? FileManager.default.removeItem(at:old) }; self.tempURL = file
                }
                DispatchQueue.main.async {
                    self.server.start { result in
                        switch result {
                        case .failure(let error): completion(error)
                        case .success(let port):
                            guard let host = device.controlURL.host, let address = Self.localAddress(for:host,port:UInt16(device.controlURL.port ?? 80)) else { completion(CastError.message("无法确定连接电视的本机网络地址。")); return }
                            let path = self.server.expose(url:file,mime:mime)
                            let uri = "http://\(address):\(port)\(path)"
                            let metadata = "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\"><item id=\"0\" parentID=\"-1\" restricted=\"1\"><dc:title>\(Self.xml(item.name))</dc:title><upnp:class>object.item.\(item.isVideo ? "videoItem" : "imageItem.photo")</upnp:class><res protocolInfo=\"http-get:*:\(mime):*\">\(Self.xml(uri))</res></item></DIDL-Lite>"
                            self.action(device,name:"SetAVTransportURI",values:[("InstanceID","0"),("CurrentURI",uri),("CurrentURIMetaData",metadata)]) { error in
                                if let error = error { DispatchQueue.main.async { completion(error) }; return }
                                self.action(device,name:"Play",values:[("InstanceID","0"),("Speed","1")]) { error in DispatchQueue.main.async { if error == nil { self.active = device }; completion(error) } }
                            }
                        }
                    }
                }
            } catch { DispatchQueue.main.async { completion(error) } }
        }
    }
    func stop(completion: @escaping (Error?) -> Void) {
        guard let device = active else { server.stop(); completion(nil); return }
        action(device,name:"Stop",values:[("InstanceID","0")]) { error in
            DispatchQueue.main.async { self.active = nil; self.server.stop(); completion(error) }
        }
    }
    func shutdown() { server.stop(); if let url = tempURL { try? FileManager.default.removeItem(at:url) }; session.invalidateAndCancel() }
}
