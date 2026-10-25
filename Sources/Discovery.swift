import Foundation

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
