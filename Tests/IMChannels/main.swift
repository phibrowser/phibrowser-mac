import Foundation

@main
struct IMChannelsTests {
    @MainActor
    static func main() async throws {
        let transport = PhiAgentTransport.shared
        let pairingJSON = #"{"id":"legacy","platform":"telegram","platformUserId":"42","platformUsername":"nova","pairedAt":"2026-08-01T00:00:00Z","localStatus":"needs_reconnect"}"#
        let pairing = try JSONDecoder().decode(ChannelPairing.self, from: Data(pairingJSON.utf8))
        let customJSON = #"{"_id":"custom","channelType":"telegram","name":"My bot","enabled":true,"status":"connected","isRunning":true}"#
        let custom = try JSONDecoder().decode(CustomBotChannel.self, from: Data(customJSON.utf8))
        let vm = IMChannelsViewModel()
        precondition(vm.isCustomBotExpanded && vm.pairing == nil)

        transport.handler = { request in
            precondition(request.method == "GET")
            switch request.path {
            case "/api/pairings":
                return .init(statusCode: 200, body: Data("{\"pairings\":[\(pairingJSON)]}".utf8))
            case "/api/custom-bot/channels":
                return .init(statusCode: 200, body: Data(#"{"channels":[],"connected":true}"#.utf8))
            case "/api/v1/agent-persona":
                return .init(statusCode: 200, body: Data(#"{"variables":{"name":"Nova"}}"#.utf8))
            default:
                preconditionFailure("Unexpected settings request: \(request.path)")
            }
        }
        await vm.loadAll()
        precondition(vm.hasLoaded && vm.pairing?.id == "legacy")
        precondition(vm.officialBotDisplayName == "nova")
        precondition(transport.requests.count == 3, "Loading must not start a pairing session")
        print("PASS: existing reconnect-needed binding loads without starting pairing")

        vm.customBot = custom
        transport.handler = { request in
            precondition(request.method == "DELETE" && request.path == "/api/pairings/legacy")
            precondition(vm.pairing?.id == "legacy" && vm.isOfficialBotLoading)
            return .init(statusCode: 503, body: Data())
        }
        await vm.disconnectOfficialBot()
        precondition(vm.pairing?.id == "legacy", "Failed unlink must preserve the binding")
        precondition(vm.customBot?.id == "custom" && vm.officialBotErrorMessage != nil)
        precondition(!vm.isOfficialBotLoading && vm.topNoticeMessages.isEmpty)
        print("PASS: failed unlink preserves both bots and keeps its error in the official section")

        let beforeUnlink = transport.requests.count
        transport.handler = { request in
            precondition(request.method == "DELETE" && request.path == "/api/pairings/legacy")
            await vm.disconnectOfficialBot()
            precondition(vm.pairing?.id == "legacy", "Keep the binding visible until unlink succeeds")
            return .init(statusCode: 200, body: Data())
        }
        await vm.disconnectOfficialBot()
        precondition(transport.requests.count == beforeUnlink + 1, "Ignore repeated unlink while busy")
        precondition(vm.pairing == nil && vm.officialBotErrorMessage == nil && !vm.isOfficialBotLoading)
        precondition(vm.customBot?.id == "custom", "Unlink must not alter the custom bot")
        print("PASS: successful unlink removes only the official binding and prevents duplicate requests")

        vm.pairing = pairing
        transport.handler = { request in
            if request.method == "DELETE" {
                return .init(statusCode: 200, body: Data())
            }
            await vm.disconnectOfficialBot()
            return .init(statusCode: 200, body: Data("{\"pairings\":[\(pairingJSON)]}".utf8))
        }
        await vm.loadPairings()
        precondition(vm.pairing == nil, "An older query must not restore an unlinked binding")
        print("PASS: stale pairing responses cannot restore an unlinked binding")

        transport.handler = { _ in .init(statusCode: 503, body: Data()) }
        await vm.loadPairings()
        precondition(vm.pairing == nil && !vm.topNoticeMessages.isEmpty)
        transport.handler = { request in
            let body = request.path == "/api/pairings"
                ? #"{"pairings":[]}"#
                : #"{"channels":[],"connected":true}"#
            return .init(statusCode: 200, body: Data(body.utf8))
        }
        await vm.refreshAll()
        precondition(vm.pairing == nil && vm.officialBotErrorMessage == nil)
        print("PASS: pairing query errors stay visible and clear after a successful refresh")

        ApplicationState.shared.isAuthenticated = false
        vm.pairing = pairing
        let beforeGuest = transport.requests.count
        await vm.disconnectOfficialBot()
        precondition(transport.requests.count == beforeGuest && vm.pairing?.id == "legacy")
        print("PASS: signed-out users cannot unlink")
    }
}
