import AppKit
import ManagedSettings
import ManagedSettingsUI

class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    private func blockedConfiguration() -> ShieldConfiguration {
        ShieldConfiguration(
            title: ShieldConfiguration.Label(
                text: "This app is blocked by your schedule",
                color: .labelColor
            ),
            subtitle: ShieldConfiguration.Label(
                text: "Come back when your scheduled time is available",
                color: .secondaryLabelColor
            ),
            primaryButtonLabel: ShieldConfiguration.Label(
                text: "Close",
                color: .white
            ),
            primaryButtonBackgroundColor: .systemBlue
        )
    }

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        blockedConfiguration()
    }

    override func configuration(shielding application: Application,
                                in category: ActivityCategory) -> ShieldConfiguration {
        blockedConfiguration()
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        blockedConfiguration()
    }

    override func configuration(shielding webDomain: WebDomain,
                                in category: ActivityCategory) -> ShieldConfiguration {
        blockedConfiguration()
    }
}
