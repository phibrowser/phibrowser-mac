import Cocoa
import Settings
import SnapKit

final class DevicesSettingViewController: NSViewController, SettingsPane {
    var paneIdentifier = Settings.PaneIdentifier.devices
    var paneTitle = NSLocalizedString("Devices", comment: "Settings - Tab title for device management")
    var toolbarItemIcon = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil) ?? NSImage()

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
