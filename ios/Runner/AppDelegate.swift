import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    registerAppIconChannel()
    return launched
  }

  // Launcher icon per trade. The alternate icon sets are AppIcon-<trade> in
  // Assets.xcassets (ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES in the
  // project). iOS shows its own one-line notice when the icon changes.
  private func registerAppIconChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else { return }
    let channel = FlutterMethodChannel(name: "com.devmonks.smartbizz/app_icon",
                                       binaryMessenger: controller.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      let app = UIApplication.shared
      switch call.method {
      case "current":
        let name = app.alternateIconName?.replacingOccurrences(of: "AppIcon-", with: "") ?? "brand"
        result(name)
      case "set":
        guard app.supportsAlternateIcons else { result(false); return }
        let args = call.arguments as? [String: Any]
        let wanted = (args?["name"] as? String ?? "brand").lowercased()
        let target: String? = wanted == "brand" ? nil : "AppIcon-\(wanted)"
        if app.alternateIconName == target { result(false); return }
        app.setAlternateIconName(target) { error in
          if let error = error {
            result(FlutterError(code: "APP_ICON", message: error.localizedDescription, details: nil))
          } else {
            result(true)
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
