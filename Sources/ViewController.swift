import UIKit
import WebKit

/// 界面就是 WKWebView 加载本机 8765 端口的内嵌页面，
/// 和 Android 端共用同一份 index.html，两端体验完全一致。
final class ViewController: UIViewController, WKUIDelegate, WKNavigationDelegate {

    private var web: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true

        web = WKWebView(frame: view.bounds, configuration: cfg)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.uiDelegate = self
        web.navigationDelegate = self
        view.addSubview(web)

        if #available(iOS 16.4, *) {
            web.isInspectable = true
        }
        reload()
        // 服务可能比界面晚几十毫秒就绪
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.reload() }
    }

    private func reload() {
        guard let url = URL(string: "http://127.0.0.1:\(LanServer.port)/") else { return }
        web.load(URLRequest(url: url))
    }

    // MARK: - 下载：页面里点文件是 location 跳转，WKWebView 不会自行保存，这里接管
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url,
           url.path == "/api/get",
           let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let target = comps.queryItems?.first(where: { $0.name == "path" })?.value,
           !target.isEmpty {
            decisionHandler(.cancel)
            self.download(from: url, saveAs: (target as NSString).lastPathComponent)
            return
        }
        decisionHandler(.allow)
    }

    private func download(from url: URL, saveAs name: String) {
        URLSession.shared.downloadTask(with: url) { tmp, _, err in
            DispatchQueue.main.async {
                guard let tmp = tmp, err == nil else {
                    self.alert("下载失败", err?.localizedDescription ?? "未知错误")
                    return
                }
                let fm = FileManager.default
                let dir = LanServer.downloadDir()
                let dst = URL(fileURLWithPath: dir).appendingPathComponent(name)
                try? fm.removeItem(at: dst)
                do {
                    try fm.moveItem(at: tmp, to: dst)
                    self.alert("已保存", dst.path)
                } catch {
                    self.alert("保存失败", error.localizedDescription)
                }
            }
        }.resume()
    }

    private func alert(_ title: String, _ msg: String) {
        let a = UIAlertController(title: title, message: msg, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default))
        present(a, animated: true)
    }
}
