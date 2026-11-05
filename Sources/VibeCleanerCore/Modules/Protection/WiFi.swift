import CoreWLAN
import Foundation

/// Known Wi-Fi networks, read through CoreWLAN. A ticked network is forgotten with `networksetup`
/// (administrator password, in the root batch); System Settings stays linked. No location access is requested,
/// so macOS may hide the network names, and a masked network can only be forgotten in System Settings.
enum WiFi {
    struct Network: Equatable {
        let ssid: String?
        let open: Bool
    }

    static let settingsURL = "x-apple.systempreferences:com.apple.wifi-settings-extension"

    static func interfaceName() -> String? { CWWiFiClient.shared().interface()?.interfaceName }

    static func known() -> [Network] {
        guard let profiles = CWWiFiClient.shared().interface()?.configuration()?.networkProfiles else { return [] }
        return profiles.array.compactMap { $0 as? CWNetworkProfile }.map { Network(ssid: $0.ssid, open: $0.security == .none) }
    }

    static func group(_ networks: [Network], interface: String? = nil) -> ResultGroup {
        func items(_ open: Bool) -> [ResultItem] {
            networks.enumerated().filter { $0.element.open == open }.map { i, n in
                let action: ItemAction = if let ssid = n.ssid, let interface {
                    .command(executable: "/usr/sbin/networksetup", arguments: ["-removepreferredwirelessnetwork", interface, ssid], admin: true)
                } else { .none }
                let kind = open ? "Réseau ouvert, sans mot de passe" : "Réseau sécurisé"
                return ResultItem(id: "privacy.wifi.\(i).\(n.ssid ?? "")", name: n.ssid ?? "Réseau au nom masqué",
                                  detail: action == .none ? kind : "\(kind) · coché, il sera oublié",
                                  symbol: open ? "wifi.exclamationmark" : "wifi", action: action, autoSelect: false)
            }
        }
        var groups: [ResultGroup] = []
        let open = items(true), secure = items(false)
        if !open.isEmpty { groups.append(ResultGroup(id: "privacy.wifi.open", title: "Réseaux ouverts", symbol: "wifi.exclamationmark", items: open, autoSelect: false)) }
        if !secure.isEmpty { groups.append(ResultGroup(id: "privacy.wifi.secure", title: "Réseaux sécurisés", symbol: "wifi", items: secure, autoSelect: false)) }
        let hidden = networks.contains { $0.ssid == nil }
        return ResultGroup(id: "privacy.wifi", title: "Réseaux Wi-Fi connus",
                           subtitle: "Votre Mac se reconnecte seul à ces réseaux. Cochez ceux qui ne servent plus pour les oublier."
                               + (hidden ? " Les noms sont masqués par macOS sans accès à la localisation." : ""),
                           symbol: "wifi", groups: groups, items: networks.isEmpty ? [] : [settingsLink("privacy.wifi.settings", "Gérer les réseaux dans Réglages Wi-Fi", settingsURL)],
                           autoSelect: false).oneByOne()
    }
}
