import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Held for the window's life: the channel answers only while it exists.
  private var folderAccess: FolderAccess?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    folderAccess = FolderAccess(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

/// The `xtremio/folder_access` channel: security-scoped bookmarks for the
/// folders chosen for the Library's Local list
/// (lib/features/local/folder_access.dart).
///
/// A sandboxed app may read a folder the viewer picked only until it quits;
/// a bookmark taken while it still may is how it reads the folder again.
///
/// - `bookmark` `{path}` -> the folder's bookmark, base64.
/// - `open` `{bookmark}` -> `{path, bookmark}` after starting access; the
///   bookmark is a fresh one when the system called the old one stale.
///   Access is held for the rest of the run.
class FolderAccess {
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "xtremio/folder_access", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any]
      switch call.method {
      case "bookmark":
        guard let path = args?["path"] as? String else {
          result(FlutterError(code: "args", message: "path", details: nil))
          return
        }
        do {
          let data = try URL(fileURLWithPath: path, isDirectory: true).bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
          result(data.base64EncodedString())
        } catch {
          result(FlutterError(code: "bookmark", message: error.localizedDescription, details: nil))
        }
      case "open":
        guard let encoded = args?["bookmark"] as? String,
          let data = Data(base64Encoded: encoded)
        else {
          result(FlutterError(code: "args", message: "bookmark", details: nil))
          return
        }
        do {
          var stale = false
          let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale)
          guard url.startAccessingSecurityScopedResource() else {
            result(FlutterError(code: "denied", message: nil, details: nil))
            return
          }
          var bookmark = encoded
          if stale,
            let fresh = try? url.bookmarkData(
              options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
              includingResourceValuesForKeys: nil,
              relativeTo: nil)
          {
            bookmark = fresh.base64EncodedString()
          }
          result(["path": url.path, "bookmark": bookmark])
        } catch {
          result(FlutterError(code: "open", message: error.localizedDescription, details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
