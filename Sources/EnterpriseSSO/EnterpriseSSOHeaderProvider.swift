// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import AppKit
import AuthenticationServices

/// Asks the device's Apple Extensible SSO extension for the Microsoft Entra
/// request headers it holds, and reports them as plain header names/values.
///
/// This mirrors Chromium's own client
/// (`chrome/browser/enterprise/platform_auth/extensible_enterprise_sso_provider_mac.mm`):
/// the same `get_sso_cookies` operation, the same `sso_url` / `types_of_header` /
/// `msg_protocol_ver` options, and no user interface, so a Mac that cannot answer
/// silently fails instead of prompting. The response carries the PRT and device
/// credentials the IdP expects as request headers; attaching them to requests for
/// the IdP origin is the framework's half of the feature (see
/// `EnterpriseSSOHeaders` and issue #383).
final class EnterpriseSSOHeaderProvider: NSObject {
    /// Response keys the extension answers with, as Chromium reads them.
    static let prtHeadersKey = "prt_headers"
    static let deviceHeadersKey = "device_headers"
    /// Each entry is `{ "header": { "<name>": "<value>", ... }, ... }`.
    static let headerEntryKey = "header"

    private var controller: ASAuthorizationController?
    private var completion: (([String: String]) -> Void)?
    private var anchorProvider: (() -> NSWindow?)?

    /// Whether the device has an SSO extension that can authenticate for `idpURL`.
    static func canAuthenticate(_ idpURL: URL) -> Bool {
        ASAuthorizationSingleSignOnProvider(identityProvider: idpURL).canPerformAuthorization
    }

    /// Starts the header request. `completion` runs on the main thread with the
    /// headers the extension returned, or an empty dictionary when the device
    /// cannot answer: an empty result is the normal outcome on an unmanaged Mac
    /// or when no PRT exists yet, not an error worth surfacing.
    ///
    /// Keep the provider alive until `completion` runs; `ASAuthorizationController`
    /// holds its delegate weakly.
    func requestHeaders(for idpURL: URL,
                        presentationAnchor: (() -> NSWindow?)?,
                        completion: @escaping ([String: String]) -> Void) {
        guard controller == nil else { return }
        let provider = ASAuthorizationSingleSignOnProvider(identityProvider: idpURL)
        guard provider.canPerformAuthorization else {
            completion([:])
            return
        }

        let request = provider.createRequest()
        request.requestedOperation = ASAuthorization.OpenIDOperation(rawValue: "get_sso_cookies")
        if #available(macOS 12, *) {
            request.isUserInterfaceEnabled = false
        }
        request.authorizationOptions = [
            URLQueryItem(name: "sso_url", value: idpURL.absoluteString),
            // 0 -> every header the extension holds (PRT and device credentials).
            URLQueryItem(name: "types_of_header", value: "0"),
            URLQueryItem(name: "msg_protocol_ver", value: "4"),
        ]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        self.completion = completion
        self.anchorProvider = presentationAnchor
        controller.performRequests()
    }

    /// Flattens the extension's response into the request headers to attach.
    ///
    /// The Entra extension nests the useful values under `prt_headers` and
    /// `device_headers`, either as arrays of `{ "header": { name: value } }` or
    /// as the JSON text of that array; older builds answer with flat `x-ms-*`
    /// header names instead. Every shape is read here so a framework-side change
    /// to the response does not silently drop the credentials.
    static func requestHeaders(fromResponseHeaders fields: [AnyHashable: Any]) -> [String: String] {
        var headers: [String: String] = [:]

        for key in [prtHeadersKey, deviceHeadersKey] {
            guard let value = fields[key] else { continue }
            addNestedHeaders(from: value, to: &headers)
        }

        for (key, value) in fields {
            guard let name = key as? String,
                  name.lowercased().hasPrefix("x-ms-"),
                  let value = value as? String else { continue }
            addHeader(name: name, value: value, to: &headers)
        }

        return headers
    }

    private static func addNestedHeaders(from value: Any, to headers: inout [String: String]) {
        let entries: [Any]
        if let array = value as? [Any] {
            entries = array
        } else if let text = value as? String,
                  let data = text.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            entries = decoded
        } else if let dictionary = value as? [String: Any] {
            entries = [dictionary]
        } else {
            return
        }

        for entry in entries {
            guard let entry = entry as? [String: Any] else { continue }
            if let header = entry[headerEntryKey] as? [String: Any] {
                for (name, rawValue) in header {
                    guard let value = rawValue as? String else { continue }
                    addHeader(name: name, value: value, to: &headers)
                }
            } else {
                // Flat shape: the entry itself is the header dictionary.
                for (name, rawValue) in entry {
                    guard let value = rawValue as? String else { continue }
                    addHeader(name: name, value: value, to: &headers)
                }
            }
        }
    }

    private static func addHeader(name: String, value: String, to headers: inout [String: String]) {
        guard isValidHeaderName(name) else { return }
        guard !value.isEmpty,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return }
        headers[name] = value
    }

    /// RFC 7230 token check, the same gate Chromium applies before handing a
    /// header to the network stack.
    private static func isValidHeaderName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9":
                return true
            case "!", "#", "$", "%", "&", "'", "*", "+", "-", ".", "^", "_", "`", "|", "~":
                return true
            default:
                return false
            }
        }
    }

    private func finish(with headers: [String: String]) {
        let completion = self.completion
        self.completion = nil
        self.controller = nil
        self.anchorProvider = nil
        completion?(headers)
    }
}

extension EnterpriseSSOHeaderProvider: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationSingleSignOnCredential,
              let response = credential.authenticatedResponse else {
            finish(with: [:])
            return
        }
        finish(with: Self.requestHeaders(fromResponseHeaders: response.allHeaderFields))
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        let error = error as NSError
        // Not interactive, no PRT, or no extension for this origin: all normal
        // on unmanaged Macs and all answered the same way, with no headers.
        AppLogInfo("[EnterpriseSSO] header request failed: \(error.domain) \(error.code)")
        finish(with: [:])
    }
}

extension EnterpriseSSOHeaderProvider: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        anchorProvider?() ?? NSApp.keyWindow ?? ASPresentationAnchor()
    }
}
