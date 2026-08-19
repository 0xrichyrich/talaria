import XCTest
import TalariaKit
@testable import TalariaUI

final class InferenceProviderManagementTests: XCTestCase {
    func testOAuthProviderParsesAllPortableFlowAndDisconnectMetadata() {
        let row = InferenceOAuthProvider(.object([
            "id": "openai-codex", "name": "ChatGPT or Codex Subscription",
            "flow": "device_code", "cli_command": "hermes auth add openai-codex",
            "docs_url": "https://platform.openai.com/docs",
            "disconnectable": true,
            "status": .object([
                "logged_in": true, "source": "openai_codex",
                "source_label": "device_code", "token_preview": "…1234",
                "has_refresh_token": false,
            ]),
        ]))

        XCTAssertEqual(row.id, "openai-codex")
        XCTAssertEqual(row.flow, .deviceCode)
        XCTAssertEqual(row.cliCommand, "hermes auth add openai-codex")
        XCTAssertTrue(row.disconnectable)
        XCTAssertTrue(row.status.loggedIn)
        XCTAssertEqual(row.status.tokenPreview, "…1234")
    }

    func testOAuthStartParsesPKCEAndDeviceCodeWithoutMixingURLs() {
        let pkce = InferenceOAuthStart(.object([
            "session_id": "pkce-1", "flow": "pkce",
            "auth_url": "https://claude.ai/oauth/authorize", "expires_in": 900,
        ]))
        XCTAssertEqual(pkce.flow, .pkce)
        XCTAssertEqual(pkce.authorizationURL?.host, "claude.ai")
        XCTAssertNil(pkce.verificationURL)

        let device = InferenceOAuthStart(.object([
            "session_id": "device-1", "flow": "device_code", "user_code": "ABCD-EFGH",
            "verification_url": "https://example.test/device", "expires_in": 600,
            "poll_interval": 0,
        ]))
        XCTAssertEqual(device.flow, .deviceCode)
        XCTAssertNil(device.authorizationURL)
        XCTAssertEqual(device.verificationURL?.path, "/device")
        XCTAssertEqual(device.pollInterval, 1)
    }

    func testOAuthBrowserURLsFailClosedToHTTPAndHTTPS() {
        let start = InferenceOAuthStart(.object([
            "session_id": "s1", "flow": "pkce", "auth_url": "talaria://steal-token",
        ]))
        let provider = InferenceOAuthProvider(.object([
            "id": "external", "flow": "external", "docs_url": "file:///etc/passwd",
            "status": .object([:]),
        ]))
        XCTAssertNil(start.authorizationURL)
        XCTAssertNil(provider.docsURL)
    }

    func testCustomEndpointCatalogPreservesModelChoiceAndSecretMetadata() {
        let catalog = CustomInferenceEndpointCatalog(.object([
            "endpoints": .array([.object([
                "id": "custom:lab", "name": "Lab", "base_url": "http://lab.test/v1",
                "model": "model-b", "models": ["model-a", "model-b"],
                "context_length": 131_072, "discover_models": true,
                "has_api_key": true, "api_key_preview": "${HERMES_CUSTOM_LAB_API_KEY}",
                "is_current": true, "source": "providers",
            ])]),
            "current": .object([
                "provider": "custom:lab", "model": "model-b",
                "base_url": "http://lab.test/v1",
            ]),
        ]))

        XCTAssertEqual(catalog.currentProvider, "custom:lab")
        XCTAssertEqual(catalog.endpoints.first?.models, ["model-a", "model-b"])
        XCTAssertEqual(catalog.endpoints.first?.contextLength, 131_072)
        XCTAssertEqual(catalog.endpoints.first?.apiKeyPreview, "${HERMES_CUSTOM_LAB_API_KEY}")
    }

    func testCustomEndpointDraftDistinguishesPreserveClearAndReplaceKey() {
        func body(_ key: String?) -> [String: JSONValue] {
            CustomInferenceEndpointDraft(name: "Local", baseURL: "http://localhost:11434/v1",
                                         model: "qwen", apiKey: key).wireValue.objectValue ?? [:]
        }
        XCTAssertNil(body(nil)["api_key"])
        XCTAssertEqual(body("")["api_key"], .string(""))
        XCTAssertEqual(body("secret")["api_key"], .string("secret"))
    }

    func testSavedWriteOnlyKeyMustBeReenteredForEndpointValidation() {
        XCTAssertTrue(CustomInferenceEndpointValidationPolicy.requiresAPIKeyReentry(
            hasSavedKey: true, apiKeyChanged: false))
        XCTAssertFalse(CustomInferenceEndpointValidationPolicy.requiresAPIKeyReentry(
            hasSavedKey: true, apiKeyChanged: true))
        XCTAssertFalse(CustomInferenceEndpointValidationPolicy.requiresAPIKeyReentry(
            hasSavedKey: false, apiKeyChanged: false))
    }

    func testOAuthSessionTargetPreservesOriginalGatewayAndProfile() {
        let target = InferenceOAuthSessionTarget(gatewayID: "homelab", profile: "research",
                                                 sessionID: "pkce-1")
        XCTAssertEqual(target.gatewayID, "homelab")
        XCTAssertEqual(target.profile, "research")
        XCTAssertEqual(target.sessionID, "pkce-1")
    }

    func testEndpointMutationTargetPreservesSourceWhenIDsCollide() {
        let reviewed = InferenceEndpointMutationTarget(gatewayID: "gateway-a", profile: "alpha",
                                                       endpointID: "custom:local")
        let colliding = InferenceEndpointMutationTarget(gatewayID: "gateway-b", profile: "beta",
                                                        endpointID: "custom:local")

        XCTAssertNotEqual(reviewed, colliding)
        XCTAssertEqual(reviewed.gatewayID, "gateway-a")
        XCTAssertEqual(reviewed.profile, "alpha")
    }

    func testEditingActiveEndpointRefreshesHermesActiveModelMirror() {
        func endpoint(current: Bool) -> CustomInferenceEndpoint {
            CustomInferenceEndpoint(.object([
                "id": "custom:lab", "name": "Lab", "base_url": "http://lab.test/v1",
                "model": "model-b", "models": ["model-a", "model-b"],
                "discover_models": true, "is_current": .bool(current),
            ]))
        }

        XCTAssertTrue(CustomInferenceEndpointEditorSeed(endpoint: endpoint(current: true)).makeDefault)
        XCTAssertFalse(CustomInferenceEndpointEditorSeed(endpoint: endpoint(current: false)).makeDefault)
    }

    func testOAuthPollUnknownStateFailsClosed() {
        let poll = InferenceOAuthPoll(.object([
            "session_id": "s1", "status": "future_state",
        ]))
        XCTAssertEqual(poll.state, .error)
    }
}
