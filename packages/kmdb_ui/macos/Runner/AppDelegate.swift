import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var accessedUrls: [String: URL] = [:]

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    let controller = mainFlutterWindow?.contentViewController as! FlutterViewController
    let channel = FlutterMethodChannel(name: "com.kmdb.browser/bookmarks",
                                     binaryMessenger: controller.engine.binaryMessenger)

    channel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "getBookmark":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Path missing", details: nil))
          return
        }
        let url = URL(fileURLWithPath: path)
        do {
          // withSecurityScope allows the bookmark to persist outside the current process
          let data = try url.bookmarkData(options: .withSecurityScope,
                                         includingResourceValuesForKeys: nil,
                                         relativeTo: nil)
          result(data.base64EncodedString())
        } catch {
          result(FlutterError(code: "BOOKMARK_ERROR", message: error.localizedDescription, details: nil))
        }

      case "startAccessing":
        guard let args = call.arguments as? [String: Any],
              let bookmarkBase64 = args["bookmark"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Bookmark missing", details: nil))
          return
        }
        guard let data = Data(base64Encoded: bookmarkBase64) else {
          result(FlutterError(code: "INVALID_ARGS", message: "Invalid base64", details: nil))
          return
        }

        do {
          var isStale = false
          let url = try URL(resolvingBookmarkData: data,
                            options: .withSecurityScope,
                            relativeTo: nil,
                            bookmarkDataIsStale: &isStale)
          
          if url.startAccessingSecurityScopedResource() {
            self.accessedUrls[url.path] = url
            result(url.path)
          } else {
            result(FlutterError(code: "ACCESS_DENIED", message: "Failed to start accessing", details: nil))
          }
        } catch {
          result(FlutterError(code: "RESOLVE_ERROR", message: error.localizedDescription, details: nil))
        }

      case "stopAccessing":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Path missing", details: nil))
          return
        }
        // Normalise path for comparison
        let normalisedPath = URL(fileURLWithPath: path).path
        if let url = self.accessedUrls.removeValue(forKey: normalisedPath) {
          url.stopAccessingSecurityScopedResource()
        }
        result(nil)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
    
    super.applicationDidFinishLaunching(notification)
  }
}
