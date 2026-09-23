import Cocoa
import Settings
import SnapKit

final class DevicesSettingViewController: NSViewController, SettingsPane {
    var paneIdentifier = Settings.PaneIdentifier.devices
    var paneTitle = NSLocalizedString("sync.settings.title", value: "Sync", comment: "Settings pane title for cross-device synchronization")
    var toolbarItemIcon = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil) ?? NSImage()

    let hostingController = DevicesSettingHostingViewController()

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.size.equalTo(NSSize(width: 680, height: 561))
        }
    }
}
