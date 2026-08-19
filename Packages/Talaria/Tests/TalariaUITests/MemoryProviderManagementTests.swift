import XCTest
import TalariaKit
@testable import TalariaUI

final class MemoryProviderManagementTests: XCTestCase {
    func testInventorySeparatesGatewayStateAndSetupReadiness() {
        let value: JSONValue = [
            "active": "honcho",
            "builtin_files": ["memory": 81, "user": 19],
            "providers": [[
                "name": "honcho",
                "description": "Network memory",
                "available": false,
                "configured": true,
                "status": "unavailable",
                "setup": [
                    "pip_dependencies": ["honcho-ai"],
                    "external_dependencies": [["name": "sqlite", "install": "brew", "check": "sqlite3"]],
                    "required_env": ["HONCHO_API_KEY"],
                    "dependencies_installed": false,
                ],
            ]],
        ]

        let inventory = MemoryProviderInventory(value)

        XCTAssertEqual(inventory.activeGatewayDefault, "honcho")
        XCTAssertEqual(inventory.memoryBytes, 81)
        XCTAssertEqual(inventory.userBytes, 19)
        XCTAssertEqual(inventory.providers.first?.setup.pipDependencies, ["honcho-ai"])
        XCTAssertEqual(inventory.providers.first?.setup.externalDependencies, ["sqlite"])
        XCTAssertTrue(inventory.providers.first?.setup.hasWork == true)
    }

    func testDeclaredFieldsMapToMobileEditorKinds() {
        let value: JSONValue = [
            "name": "example",
            "label": "Example",
            "fields": [
                field("host", kind: "text", value: "localhost"),
                field("token", kind: "secret", value: "", isSet: true),
                field("mode", kind: "select", value: "fast",
                      options: [["value": "fast", "label": "Fast", "description": ""]]),
                field("enabled", kind: "bool", value: "true"),
                field("limit", kind: "number", value: "4.5"),
            ],
        ]

        let config = MemoryProviderDeclaredConfig(value)

        XCTAssertEqual(config.fields.map(\.kind), [.text, .secret, .select, .boolean, .number])
        XCTAssertEqual(config.fields[2].options.first?.value, "fast")
        XCTAssertTrue(config.fields[1].isSet)
    }

    func testBlankSecretIsOmittedWhileNonSecretBlankStillClearsOverride() {
        let value: JSONValue = [
            "name": "example",
            "fields": [
                field("token", kind: "secret", value: "", isSet: true),
                field("host", kind: "text", value: "old"),
                field("enabled", kind: "bool", value: "true"),
            ],
        ]
        let config = MemoryProviderDeclaredConfig(value)

        let submission = config.submission(from: [
            "token": "   ",
            "host": "",
            "enabled": "false",
        ])

        XCTAssertNil(submission["token"])
        XCTAssertEqual(submission["host"], .string(""))
        XCTAssertEqual(submission["enabled"], .string("false"))
    }

    func testNewSecretIsSubmittedWithoutTrimmingItsValue() {
        let value: JSONValue = [
            "name": "example",
            "fields": [field("token", kind: "secret", value: "")],
        ]
        let config = MemoryProviderDeclaredConfig(value)

        XCTAssertEqual(config.submission(from: ["token": "  opaque value  "])["token"],
                       .string("  opaque value  "))
    }

    func testCatalogKeepsProfileOnlyAndConfiguredProviders() {
        let gateway = MemoryProviderInventoryRow([
            "name": "gateway-provider", "description": "", "available": true,
            "configured": true, "status": "ready", "setup": [:],
        ])!

        let names = MemoryProviderCatalog.merge(
            profileSchema: ["", "profile-provider", "gateway-provider"],
            gatewayInventory: [gateway], active: "configured-but-missing")

        XCTAssertEqual(names, ["profile-provider", "gateway-provider", "configured-but-missing"])
    }

    func testDeclaredConfigSaveDoesNotImplyActivation() {
        XCTAssertEqual(MemoryProviderSaveSemantics.activeSelection(
            afterDeclaredSave: "builtin"), "builtin")
        XCTAssertEqual(MemoryProviderSaveSemantics.activeSelection(
                       afterDeclaredSave: "honcho"), "honcho")
    }

    func testSaveCopyPromisesConfigurationOnly() {
        let standardAction = MemoryProviderCopySemantics.saveAction(control: false)
        let standardNotice = MemoryProviderCopySemantics.savedNotice(
            control: false, provider: "honcho")
        let controlAction = MemoryProviderCopySemantics.saveAction(control: true)
        let controlNotice = MemoryProviderCopySemantics.savedNotice(
            control: true, provider: "honcho")

        XCTAssertEqual(standardAction, "Save provider configuration")
        XCTAssertTrue(standardNotice.contains("Activate it separately"))
        XCTAssertFalse((standardAction + standardNotice).lowercased().contains("selected"))
        XCTAssertEqual(controlAction, "SAVE PROVIDER CONFIG")
        XCTAssertEqual(controlNotice, "CONFIG SAVED: HONCHO")
    }

    func testDocumentationLinksRequireHTTPHost() {
        XCTAssertEqual(MemoryProviderDocumentationPolicy.externalURL(
            "https://docs.example/provider")?.absoluteString,
            "https://docs.example/provider")
        XCTAssertEqual(MemoryProviderDocumentationPolicy.externalURL(
            " http://localhost:8080/help ")?.absoluteString,
            "http://localhost:8080/help")
        XCTAssertNil(MemoryProviderDocumentationPolicy.externalURL("file:///etc/passwd"))
        XCTAssertNil(MemoryProviderDocumentationPolicy.externalURL("javascript:alert(1)"))
        XCTAssertNil(MemoryProviderDocumentationPolicy.externalURL("https:///missing-host"))
        XCTAssertNil(MemoryProviderDocumentationPolicy.externalURL("docs.example/provider"))
    }

    func testOAuthStatusParsesProfileCredentialState() {
        let status = MemoryProviderOAuthStatus([
            "state": "connected", "detail": "Honcho connected",
            "connected": true, "auth": "oauth",
        ])

        XCTAssertEqual(status.state, .connected)
        XCTAssertTrue(status.connected)
        XCTAssertEqual(status.authentication, "oauth")
    }

    func testReconnectDoesNotFinishFromOldCredentialWhileNewFlowIsPending() {
        let status = MemoryProviderOAuthStatus([
            "state": "pending", "detail": "waiting", "connected": true, "auth": "oauth",
        ])

        XCTAssertEqual(MemoryProviderOAuthPollDecision.decide(status: status, timedOut: false),
                       .keepWaiting)
        XCTAssertEqual(MemoryProviderOAuthPollDecision.decide(status: status, timedOut: true),
                       .failed("Phone polling timed out; the gateway browser flow may still finish."))
    }

    func testOAuthPollingRecognizesTerminalConnectionAndProviderError() {
        let connected = MemoryProviderOAuthStatus([
            "state": "connected", "detail": "done", "connected": true, "auth": "oauth",
        ])
        let failed = MemoryProviderOAuthStatus([
            // An old credential may remain connected when RECONNECT fails.
            "state": "error", "detail": "consent denied", "connected": true, "auth": "oauth",
        ])
        let wrongProfile = MemoryProviderOAuthStatus([
            "state": "connected", "detail": "done", "connected": false, "auth": nil,
        ])

        XCTAssertEqual(MemoryProviderOAuthPollDecision.decide(status: connected, timedOut: false),
                       .connected)
        XCTAssertEqual(MemoryProviderOAuthPollDecision.decide(status: failed, timedOut: false),
                       .failed("consent denied"))
        XCTAssertEqual(MemoryProviderOAuthPollDecision.decide(status: wrongProfile,
                                                               timedOut: false),
                       .failed("Authorization did not connect the selected profile."))
    }

    private func field(_ key: String, kind: String, value: JSONValue,
                       isSet: Bool = false, options: JSONValue = []) -> JSONValue {
        [
            "key": .string(key),
            "label": .string(key.capitalized),
            "kind": .string(kind),
            "description": "",
            "placeholder": "",
            "is_set": .bool(isSet),
            "value": value,
            "options": options,
        ]
    }
}
