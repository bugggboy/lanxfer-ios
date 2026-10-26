import Foundation
import Network

/// mDNS 发现（Bonjour）。TXT 里带 os / model / ip，
/// 对端不用连上来就能显示真实机型；带 ip 是因为 Android 的 WebView 解析不了 .local 域名。
final class Discovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static let shared = Discovery()

    struct Peer {
        var name: String
        var host: String
        var port: Int
        var os: String
        var json: String {
            "{\"name\":\"\(LanServer.esc(name))\",\"host\":\"\(LanServer.esc(host))\",\"os\":\"\(LanServer.esc(os))\",\"port\":\(port)}"
        }
    }

    private var publisher: NetService?
    private var browser: NetServiceBrowser?
    private var peers: [Peer] = []
    private let lock = NSLock()

    // MARK: TXT
    static func txtData() -> Data {
        var d = Data()
        func add(_ s: String) {
            let b = Array(s.utf8)
            d.append(UInt8(min(b.count, 255)))
            d.append(contentsOf: b.prefix(255))
        }
        add("os=ios")
        add("model=\(LanServer.model())")
        if let ip = localIP() { add("ip=\(ip)") }
        return d
    }

    /// 取 en* 网卡的 IPv4（iOS 上 WiFi 是 en0）
    static func localIP() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let ifa = p.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: ifa.ifa_name)
                if name.hasPrefix("en") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                   &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: host)
                        if !ip.isEmpty { return ip }
                    }
                }
            }
            ptr = ifa.ifa_next
        }
        return nil
    }

    // MARK: 启停
    func start() {
        let svc = NetService(domain: "local.", type: "_lanxfer._tcp.",
                             name: "lanxfer-\(LanServer.machine())",
                             port: Int32(LanServer.port))
        svc.delegate = self
        svc.setTXTRecord(Discovery.txtData())
        svc.publish()
        publisher = svc

        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: "_lanxfer._tcp.", inDomain: "local.")
        browser = b
    }

    // MARK: 结果
    func peersJson() -> String {
        lock.lock(); defer { lock.unlock() }
        return "[" + peers.map { $0.json }.joined(separator: ",") + "]"
    }

    func addManual(_ hostport: String?) {
        guard var h = hostport?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return }
        var port = Int(LanServer.port)
        if let i = h.firstIndex(of: ":") {
            port = Int(h[h.index(after: i)...]) ?? port
            h = String(h[..<i])
        }
        upsert(name: h, host: h, port: port, os: "")
    }

    // MARK: - 主动扫描（mDNS 被挡时的兜底）
    func scan(completion: @escaping () -> Void) {
        guard let ip = Discovery.localIP() else { completion(); return }
        guard let dot = ip.lastIndex(of: ".") else { completion(); return }
        let prefix = String(ip[...dot])   // "192.168.31."
        let sema = DispatchSemaphore(value: 40)
        let group = DispatchGroup()
        for i in 1...254 {
            let host = "\(prefix)\(i)"
            if host == ip { continue }
            group.enter()
            sema.wait()
            DispatchQueue.global().async {
                self.probe(host: host, timeout: 0.35) { alive in
                    if alive {
                        self.fetchInfo(host: host) { info in
                            if let info = info {
                                self.upsert(name: info.model, host: host, port: Int(LanServer.port), os: info.os)
                            }
                            sema.signal()
                            group.leave()
                        }
                    } else {
                        sema.signal()
                        group.leave()
                    }
                }
            }
        }
        group.notify(queue: .global()) { completion() }
    }

    private func probe(host: String, timeout: TimeInterval, done: @escaping (Bool) -> Void) {
        guard let port = NWEndpoint.Port(rawValue: LanServer.port) else { done(false); return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let q = DispatchQueue(label: "lanxfer.probe")
        var finished = false
        let lock = NSLock()
        func finish(_ ok: Bool) {
            lock.lock(); defer { lock.unlock() }
            if finished { return }
            finished = true
            conn.cancel()
            done(ok)
        }
        conn.stateUpdateHandler = { st in
            switch st {
            case .ready: finish(true)
            case .failed, .cancelled: finish(false)
            default: break
            }
        }
        conn.start(queue: q)
        q.asyncAfter(deadline: .now() + timeout) { finish(false) }
    }

    private func fetchInfo(host: String, done: @escaping ((model: String, os: String)?) -> Void) {
        guard let port = NWEndpoint.Port(rawValue: LanServer.port) else { done(nil); return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let q = DispatchQueue(label: "lanxfer.fetch")
        conn.stateUpdateHandler = { st in
            if case .failed = st { done(nil) }
        }
        conn.start(queue: q)
        let req = "GET /api/info HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(req.utf8), completion: .contentProcessed { _ in })
        var buf = Data()
        func recv() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { d, _, _, err in
                if let d = d { buf.append(d) }
                if err == nil && buf.count < 65536 && d != nil { recv(); return }
                conn.cancel()
                let s = String(data: buf, encoding: .utf8) ?? ""
                guard let m = Self.jsonField(s, "model") else { done(nil); return }
                done((m, Self.jsonField(s, "os") ?? ""))
            }
        }
        recv()
    }

    private static func jsonField(_ json: String, _ key: String) -> String? {
        let marker = "\"\(key)\":\""
        guard let r = json.range(of: marker) else { return nil }
        let rest = json[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// VPN 检测（启发式）：utun0 是系统自带，出现第二个 utun 或 ipsec/tap/tun 即视为 VPN
    static func vpnActive() -> Bool {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return false }
        defer { freeifaddrs(addrs) }
        var utunCount = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let name = String(cString: p.pointee.ifa_name)
            if name.hasPrefix("ipsec") || name.hasPrefix("ppp") || name.hasPrefix("tap") || name.hasPrefix("tun") {
                return true
            }
            if name.hasPrefix("utun") { utunCount += 1 }
            ptr = p.pointee.ifa_next
        }
        return utunCount >= 2
    }

    private func upsert(name: String, host: String, port: Int, os: String) {
        guard !host.isEmpty else { return }
        lock.lock()
        if let idx = peers.firstIndex(where: { $0.host == host && $0.port == port }) {
            peers[idx].name = name
            peers[idx].os = os
        } else {
            peers.append(Peer(name: name, host: host, port: port, os: os))
        }
        lock.unlock()
    }

    // MARK: NetServiceBrowserDelegate
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        if service.name.hasPrefix("lanxfer-\(LanServer.machine())") { return }
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        NSLog("lanxfer browse failed: \(errorDict)")
    }

    // MARK: NetServiceDelegate
    func netServiceDidResolveAddress(_ sender: NetService) {
        let txt = NetService.dictionary(fromTXTRecord: sender.txtRecordData() ?? Data())
        let ip = txt["ip"].flatMap { String(data: $0, encoding: .utf8) } ?? sender.hostName ?? ""
        let model = txt["model"].flatMap { String(data: $0, encoding: .utf8) } ?? sender.name
        let os = txt["os"].flatMap { String(data: $0, encoding: .utf8) } ?? ""
        upsert(name: model, host: ip, port: sender.port, os: os)
    }
}
