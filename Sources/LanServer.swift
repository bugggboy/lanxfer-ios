import Foundation
import Network
import UIKit

/// 极简 HTTP 服务（Network.framework），接口与 Android 端完全一致。
final class LanServer {
    static let port: UInt16 = 8765
    static let shared = LanServer()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "lanxfer.http", attributes: .concurrent)

    // MARK: - 设备信息
    static func machine() -> String {
        var sys = utsname()
        uname(&sys)
        let mirror = Mirror(reflecting: sys.machine)
        var out = ""
        for child in mirror.children {
            if let v = child.value as? Int8, v != 0 { out.append(Character(UnicodeScalar(UInt8(v)))) }
        }
        return out
    }

    static func model() -> String {
        let m = machine()
        let table: [String: String] = [
            "iPhone10,1": "iPhone 8", "iPhone10,4": "iPhone 8",
            "iPhone10,2": "iPhone 8 Plus", "iPhone10,5": "iPhone 8 Plus",
            "iPhone10,3": "iPhone X", "iPhone10,6": "iPhone X",
            "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max",
            "iPhone11,8": "iPhone XR", "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro",
            "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE 2",
            "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro",
            "iPhone13,4": "iPhone 12 Pro Max", "iPhone14,2": "iPhone 13 Pro", "iPhone14,5": "iPhone 13",
        ]
        if let name = table[m] { return name }
        if m.hasPrefix("iPhone") { return "iPhone (\(m))" }
        if m.hasPrefix("iPad") { return "iPad (\(m))" }
        return m.isEmpty ? "iOS Device" : m
    }

    static func osVersion() -> String { "iOS " + UIDevice.current.systemVersion }

    // MARK: - 根目录
    static func root() -> String {
        let fm = FileManager.default
        for p in ["/var/mobile", "/private/var/mobile", NSHomeDirectory()] {
            if fm.isWritableFile(atPath: p) { return p }
        }
        return NSHomeDirectory()
    }

    static func downloadDir() -> String {
        let fm = FileManager.default
        let base = root()
        let dir = base == NSHomeDirectory()
            ? (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
            : (base as NSString).appendingPathComponent("Downloads")
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 启动
    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: LanServer.port),
              let l = try? NWListener(using: params, on: port) else { return }
        listener = l
        let txt = Discovery.txtData()
        l.service = NWListener.Service(name: "lanxfer-\(LanServer.machine())",
                                       type: "_lanxfer._tcp", domain: nil, txtRecord: txt)
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: self?.queue ?? .global())
            self?.receive(conn: conn, buffer: Data())
        }
        l.stateUpdateHandler = { st in
            if case .failed(let e) = st { NSLog("lanxfer listener failed: \(e)") }
        }
        l.start(queue: queue)
    }

    // MARK: - 收请求
    private func receive(conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, err in
            guard let self = self else { return }
            var buf = buffer
            if let d = data { buf.append(d) }
            if let req = HTTPRequest.parse(buf) {
                self.handle(conn: conn, req: req)
                return
            }
            if isComplete || err != nil { conn.cancel(); return }
            self.receive(conn: conn, buffer: buf)
        }
    }

    // MARK: - 路由
    private func handle(conn: NWConnection, req: HTTPRequest) {
        if req.method == "OPTIONS" {
            respond(conn, "204 No Content", "text/plain", Data())
            return
        }
        switch req.path {
        case "/", "/index.html":
            let url = Bundle.main.url(forResource: "index", withExtension: "html")
            let data = (url.flatMap { try? Data(contentsOf: $0) }) ?? Data("<h1>ui missing</h1>".utf8)
            respond(conn, "200 OK", "text/html; charset=utf-8", data)

        case "/api/info":
            let ip = Discovery.localIP() ?? ""
            let json = "{\"model\":\"\(LanServer.esc(LanServer.model()))\",\"os\":\"ios\",\"ver\":\"\(LanServer.esc(LanServer.osVersion()))\",\"port\":\(LanServer.port),\"ip\":\"\(LanServer.esc(ip))\"}"
            respond(conn, "200 OK", "application/json; charset=utf-8", Data(json.utf8))

        case "/api/peers":
            respond(conn, "200 OK", "application/json; charset=utf-8", Data(Discovery.shared.peersJson().utf8))

        case "/api/roots":
            let r = LanServer.root()
            respond(conn, "200 OK", "application/json; charset=utf-8",
                    Data("[\"\(LanServer.esc(r))\",\"\(LanServer.esc(LanServer.downloadDir()))\"]".utf8))

        case "/api/addpeer":
            Discovery.shared.addManual(req.query["host"])
            respond(conn, "200 OK", "application/json; charset=utf-8", Data("{\"ok\":true}".utf8))

        case "/api/ls":
            respond(conn, "200 OK", "application/json; charset=utf-8", Data(listJson(req.query["path"]).utf8))

        case "/api/get":
            guard let p = req.query["path"] else { respond(conn, "404 Not Found", "text/plain", Data()); return }
            sendFile(conn, path: p)

        case "/api/put":
            guard let p = req.query["path"] else { respond(conn, "404 Not Found", "text/plain", Data()); return }
            let ok = saveFile(path: p, data: req.body)
            let json = "{\"ok\":\(ok),\"size\":\(ok ? req.body.count : 0)}"
            respond(conn, "200 OK", "application/json; charset=utf-8", Data(json.utf8))

        default:
            respond(conn, "404 Not Found", "text/plain", Data())
        }
    }

    // MARK: - 文件
    private func listJson(_ raw: String?) -> String {
        let dir = raw?.isEmpty == false ? raw! : LanServer.root()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return "{\"error\":\"not a directory\",\"path\":\"\(LanServer.esc(dir))\",\"entries\":[]}"
        }
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        var entries: [(String, Bool, UInt64)] = []
        for name in items {
            let full = (dir as NSString).appendingPathComponent(name)
            var d: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: full, isDirectory: &d)
            let size = d.boolValue ? 0 : ((try? FileManager.default.attributesOfItem(atPath: full)[.size]) as? NSNumber)?.uint64Value ?? 0
            entries.append((name, d.boolValue, size))
        }
        entries.sort { a, b in a.1 == b.1 ? a.0.lowercased() < b.0.lowercased() : a.1 }
        let body = entries.map { "{\"n\":\"\(LanServer.esc($0.0))\",\"d\":\($0.1),\"s\":\($0.2)}" }.joined(separator: ",")
        return "{\"path\":\"\(LanServer.esc(dir))\",\"entries\":[\(body)]}"
    }

    private func saveFile(path: String, data: Data) -> Bool {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return fm.createFile(atPath: path, contents: data)
    }

    private func sendFile(_ conn: NWConnection, path: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let fh = FileHandle(forReadingAtPath: path) else {
            respond(conn, "404 Not Found", "text/plain", Data())
            return
        }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: 0)
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Content-Type: \(typeFor(path))\r\n"
        head += "Content-Length: \(size)\r\n"
        head += "Connection: close\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] err in
            if err != nil { conn.cancel(); return }
            self?.pump(conn: conn, fh: fh, total: size, sent: 0)
        })
    }

    private func pump(conn: NWConnection, fh: FileHandle, total: UInt64, sent: UInt64) {
        if sent >= total {
            try? fh.close()
            conn.send(content: nil, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
            return
        }
        let chunk = fh.readData(ofLength: 256 * 1024)
        if chunk.isEmpty {
            try? fh.close()
            conn.cancel()
            return
        }
        conn.send(content: chunk, completion: .contentProcessed { [weak self] err in
            if err != nil { conn.cancel(); return }
            self?.pump(conn: conn, fh: fh, total: total, sent: sent + UInt64(chunk.count))
        })
    }

    private func typeFor(_ path: String) -> String {
        let l = path.lowercased()
        if l.hasSuffix(".jpg") || l.hasSuffix(".jpeg") { return "image/jpeg" }
        if l.hasSuffix(".png") { return "image/png" }
        if l.hasSuffix(".mp4") { return "video/mp4" }
        if l.hasSuffix(".mp3") { return "audio/mpeg" }
        if l.hasSuffix(".txt") || l.hasSuffix(".log") { return "text/plain; charset=utf-8" }
        if l.hasSuffix(".json") { return "application/json" }
        return "application/octet-stream"
    }

    // MARK: - 响应
    private func respond(_ conn: NWConnection, _ status: String, _ type: String, _ body: Data) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Methods: GET,PUT,OPTIONS\r\n"
        head += "Access-Control-Allow-Headers: Content-Type\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    static func esc(_ s: String) -> String {
        var out = ""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if c.value < 0x20 { out += String(format: "\\u%04x", c.value) }
                else { out.unicodeScalars.append(c) }
            }
        }
        return out
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let body: Data

    static func parse(_ buf: Data) -> HTTPRequest? {
        guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headData = buf.subdata(in: 0..<sep.lowerBound)
        guard let head = String(data: headData, encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        let method = String(first[0])
        let target = String(first[1])
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            let k = l[l.startIndex..<i].trimmingCharacters(in: .whitespaces).lowercased()
            let v = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }
        let bodyStart = sep.upperBound
        let len = Int(headers["content-length"] ?? "0") ?? 0
        if buf.count - bodyStart < len { return nil }
        let body = buf.subdata(in: bodyStart..<(bodyStart + len))

        var path = target
        var query: [String: String] = [:]
        if let qi = target.firstIndex(of: "?") {
            path = String(target[..<qi])
            let qs = String(target[target.index(after: qi)...])
            for kv in qs.split(separator: "&") {
                let parts = kv.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let k = String(parts[0]).removingPercentEncoding ?? String(parts[0])
                let v = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? "") : ""
                query[k] = v
            }
        }
        return HTTPRequest(method: method, path: path, query: query, body: body)
    }
}
