import XCTest
@testable import AppDockAuditEngine

private final class MemorySecrets: SecretStorage {
    var value: String?
    var failWrites = false
    func read() throws -> String? { value }
    func write(_ value: String) throws {
        if failWrites { throw CredentialError.keychainUnavailable }
        self.value = value.isEmpty ? nil : value
    }
}

private final class RequestStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.unknown) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class PrivacyTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "org.opendock.privacy-tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        RequestStub.handler = nil
    }

    func testMigrationMovesLegacyKeyOnlyAfterSuccessfulWrite() throws {
        let secrets = MemorySecrets()
        defaults.set("test-only-credential", forKey: "ai.apiKey")
        let store = APIKeyStore(storage: secrets, defaults: defaults)
        XCTAssertEqual(try store.load(), "test-only-credential")
        XCTAssertEqual(secrets.value, "test-only-credential")
        XCTAssertNil(defaults.object(forKey: "ai.apiKey"))
    }

    func testFailedMigrationPreservesExistingCredential() {
        let secrets = MemorySecrets()
        secrets.failWrites = true
        defaults.set("test-only-credential", forKey: "ai.apiKey")
        XCTAssertThrowsError(try APIKeyStore(storage: secrets, defaults: defaults).load())
        XCTAssertEqual(defaults.string(forKey: "ai.apiKey"), "test-only-credential")
    }

    func testExistingKeychainValueWinsAndRemovesStalePreference() throws {
        let secrets = MemorySecrets()
        secrets.value = "current-test-credential"
        defaults.set("legacy-test-credential", forKey: "ai.apiKey")
        XCTAssertEqual(try APIKeyStore(storage: secrets, defaults: defaults).load(), secrets.value)
        XCTAssertNil(defaults.object(forKey: "ai.apiKey"))
    }

    func testDeletingCredentialRemovesBothStorageLocations() throws {
        let secrets = MemorySecrets()
        secrets.value = "test-only-credential"
        defaults.set("stale-test-credential", forKey: "ai.apiKey")
        try APIKeyStore(storage: secrets, defaults: defaults).save("")
        XCTAssertNil(secrets.value)
        XCTAssertNil(defaults.object(forKey: "ai.apiKey"))
    }

    func testConsentDefaultsOffAndIsBoundToSavedEndpoint() throws {
        let endpoint = "https://service.invalid/v1"
        XCTAssertThrowsError(try AIPrivacyPolicy.authorize(endpoint, defaults: defaults))
        AIPrivacyPolicy.saveConsent(true, endpoint: endpoint + "/", defaults: defaults)
        XCTAssertNoThrow(try AIPrivacyPolicy.authorize(endpoint, defaults: defaults))
        XCTAssertThrowsError(try AIPrivacyPolicy.authorize("https://other.invalid/v1", defaults: defaults))
        AIPrivacyPolicy.saveConsent(false, endpoint: endpoint, defaults: defaults)
        XCTAssertThrowsError(try AIPrivacyPolicy.authorize(endpoint, defaults: defaults))
    }

    func testRejectsInsecureAndCredentialBearingEndpoints() {
        for endpoint in ["http://service.invalid/v1", "https://account:password@service.invalid/v1", "https://service.invalid/v1?key=test", "https://service.invalid/v1#private"] {
            AIPrivacyPolicy.saveConsent(true, endpoint: endpoint, defaults: defaults)
            XCTAssertThrowsError(try AIPrivacyPolicy.authorize(endpoint, defaults: defaults))
        }
    }

    func testSanitizerRemovesHomesEmailsAndConfiguredKey() {
        let home = "/" + "Users/fixture-person/Library/Cache"
        let email = "fixture-person" + "@example.invalid"
        let secret = "test-only-credential"
        let result = AIPrivacyPolicy.sanitize("\(home) \(email) \(secret)", apiKey: secret)
        XCTAssertFalse(result.contains("fixture-person"))
        XCTAssertFalse(result.contains(secret))
        XCTAssertTrue(result.contains("[private home]"))
        XCTAssertTrue(result.contains("[email removed]"))
    }

    func testAdapterRejectsBeforeAnyNetworkRequest() async {
        var requested = false
        let session = stubSession { _ in requested = true; throw URLError(.badServerResponse) }
        defer { session.invalidateAndCancel() }
        do {
            _ = try await OpenAICompatibleAdapter(session: session, defaults: defaults).complete(prompt: "example", payload: Data("[]".utf8), config: config)
            XCTFail("Unapproved request was allowed")
        } catch { XCTAssertTrue(error is AIPrivacyError) }
        XCTAssertFalse(requested)
    }

    func testAdapterSanitizesDirectPromptAndPayloadBeforeTransport() async throws {
        AIPrivacyPolicy.saveConsent(true, endpoint: config.baseURL, defaults: defaults)
        let home = "/" + "Users/fixture-person/Library/Cache"
        let session = stubSession { request in
            let data = try self.body(of: request)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            let content = messages.compactMap { $0["content"] }.joined()
            XCTAssertFalse(content.contains("fixture-person"))
            XCTAssertFalse(content.contains(self.config.apiKey))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + self.config.apiKey)
            return (200, Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8))
        }
        defer { session.invalidateAndCancel() }
        let result = try await OpenAICompatibleAdapter(session: session, defaults: defaults).complete(prompt: home + " " + config.apiKey, payload: Data(home.utf8), config: config)
        XCTAssertEqual(result.content, "ok")
    }

    func testServerErrorDoesNotExposeResponseBody() async {
        AIPrivacyPolicy.saveConsent(true, endpoint: config.baseURL, defaults: defaults)
        let session = stubSession { _ in (400, Data("private-response-with-test-credential".utf8)) }
        defer { session.invalidateAndCancel() }
        do {
            _ = try await OpenAICompatibleAdapter(session: session, defaults: defaults).complete(prompt: "example", payload: Data("[]".utf8), config: config)
            XCTFail("Expected server rejection")
        } catch { XCTAssertFalse(error.localizedDescription.contains("private-response")) }
    }

    func testLocalHistoryDefaultsOffAndCanBeEnabled() {
        XCTAssertFalse(LocalDataPrivacy.historyEnabled(defaults: defaults))
        defaults.set(true, forKey: "privacy.localHistoryEnabled")
        XCTAssertTrue(LocalDataPrivacy.historyEnabled(defaults: defaults))
    }

    func testClearLocalDataPreservesUnrelatedFilesAndCredential() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["app-cache.json", "search_feedback.json", "unrelated.txt"] {
            try Data("fixture".utf8).write(to: directory.appendingPathComponent(name))
        }
        defaults.set("test-only-credential", forKey: "ai.apiKey")
        defaults.set("fixture-history", forKey: "app.recentUsage")
        try LocalDataPrivacy.clear(defaults: defaults, directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("app-cache.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("search_feedback.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("unrelated.txt").path))
        XCTAssertNil(defaults.object(forKey: "app.recentUsage"))
        XCTAssertEqual(defaults.string(forKey: "ai.apiKey"), "test-only-credential")
    }

    private var config: AIProviderConfig {
        AIProviderConfig(apiKey: "test-only-credential", baseURL: "https://service.invalid/v1", model: "fixture-model", temperature: 0, maxTokens: 100)
    }

    private func stubSession(_ handler: @escaping (URLRequest) throws -> (Int, Data)) -> URLSession {
        RequestStub.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestStub.self]
        return URLSession(configuration: configuration)
    }

    private func body(of request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
