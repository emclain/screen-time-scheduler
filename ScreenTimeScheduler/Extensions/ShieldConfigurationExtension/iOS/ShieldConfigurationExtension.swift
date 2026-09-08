import ManagedSettings
import ManagedSettingsUI
import UIKit

class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    private func blockedConfiguration() -> ShieldConfiguration {
        ShieldConfiguration(
            backgroundBlurStyle: .systemUltraThinMaterial,
            title: ShieldConfiguration.Label(
                text: "This app is blocked by your schedule",
                color: .label
            ),
            subtitle: ShieldConfiguration.Label(
                text: "Come back when your scheduled time is available",
                color: .secondaryLabel
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
