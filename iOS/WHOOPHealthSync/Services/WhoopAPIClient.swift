import Foundation
import WHOOPHealthSyncCore

struct WhoopPrivateAPIConfiguration {
    var baseURL = URL(string: "https://api.prod.whoop.com")!
    var preferredHeartRateStepSeconds = 6
    var requestTimeoutSeconds: TimeInterval = 30
}

/// Results of the cycles payload reads used by the best-effort sync steps. They live next to the client
/// so the API smoke check compiles without the sync engine.
struct SkinTemperatureFetch {
    var readings: [SkinTemperatureReading]
    var recoveryKeys: [String]
}

struct NightlyVitalsFetch {
    var readings: [NightlyVitalReading]
    var fieldNames: [String]
}

final class WhoopAPIClient {
    private let auth: WhoopAuthService
    private let session: URLSession
    private let configuration: WhoopPrivateAPIConfiguration
    private var deepDiveSleepSessionCache: [String: SleepSession] = [:]
    private let deepDiveActivityPrefix = "deep-dive-sleep:"

    init(
        auth: WhoopAuthService,
        session: URLSession = .shared,
        configuration: WhoopPrivateAPIConfiguration = WhoopPrivateAPIConfiguration()
    ) {
        self.auth = auth
        self.session = session
        self.configuration = configuration
    }

    private var recoveryRetryNotBefore: Date?

    func fetchRecoveryCycleRecords(userID: String, window: TimeRange) async throws -> [[String: Any]] {
        if let date = recoveryRetryNotBefore, date > Date() { throw RecoverySyncError.rateLimited(until: date) }
        let json = try await getJSON(path: "/core-details-bff/v0/cycles/details", query: [
            "id": userID, "startTime": Self.isoString(window.start), "endTime": Self.isoString(window.end), "limit": "50"
        ], recoveryRequest: true)
        guard let root = json as? [String: Any], let records = root["records"] as? [[String: Any]] else { throw RecoverySyncError.invalidRecord }
        return records
    }

    func probeExistingCyclesSchema() async throws -> String {
        let user = try await fetchCurrentUser()
        let end = Date()
        let json = try await getJSON(path: "/core-details-bff/v0/cycles/details", query: [
            "id": user.id, "startTime": Self.isoString(end.addingTimeInterval(-7 * 86400)),
            "endTime": Self.isoString(end), "limit": "50"
        ])
        return WhoopContractProbe.schema(of: json)
    }

    func probeRecoveryValues() async throws -> String {
        let user = try await fetchCurrentUser()
        let end = Date()
        // The user declared December 2025 as their approximate start month.
        // This is a diagnostic window, not a proven boundary for historical import.
        guard let initialStart = WhoopDateCodec.date(from: "2025-12-01T00:00:00Z"),
              let initialEnd = WhoopDateCodec.date(from: "2026-01-01T00:00:00Z") else { throw RecoverySyncError.invalidTemporalAssociation }
        var sections = ["Diagnóstico de solo lectura. No escribe en Salud ni cambia avances. Campo privado hrv_rmssd en segundos: conversión ×1000 a ms respaldada por las siete referencias WHOOP aportadas. Comparar por fecha de fin de sueño: 13/09/2026=46 ms, 14/09/2026=59 ms, 15/09/2026=48 ms. Inicio aproximado de uso declarado: diciembre de 2025; no se consulta antes de ese mes."]
        let windows: [(String, Date, Date, Int)] = [
            ("Últimos siete días", end.addingTimeInterval(-7 * 86400), end, 20),
            ("Inicio aproximado declarado: diciembre de 2025 (sondeo mensual; no demuestra exhaustividad)", initialStart, initialEnd, 10)
        ]
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            do {
                let json = try await getJSON(path: "/core-details-bff/v0/cycles/details", query: [
                    "id": user.id, "startTime": Self.isoString(window.1), "endTime": Self.isoString(window.2), "limit": "50"
                ])
                sections.append(window.0 + "\n" + WhoopRecoveryValueProbe.report(of: json, expectedUserID: user.id, maxRows: window.3))
            } catch {
                try Task.checkCancellation()
                if index == 0 { throw error }
                sections.append(window.0 + "\nConsulta no completada; no equivale a histórico vacío.")
            }
        }
        return sections.joined(separator: "\n\n")
    }

    func fetchSkinTemperatures(userID: String, start: Date, end: Date) async throws -> SkinTemperatureFetch {
        let json = try await getJSON(path: "/core-details-bff/v0/cycles/details", query: [
            "id": userID, "startTime": Self.isoString(start), "endTime": Self.isoString(end), "limit": "50"
        ])
        return SkinTemperatureFetch(readings: WhoopSkinTemperatureAdapter.readings(fromCyclesJSON: json),
                                    recoveryKeys: WhoopSkinTemperatureAdapter.recoveryKeys(fromCyclesJSON: json))
    }

    func fetchNightlyVitals(userID: String, start: Date, end: Date) async throws -> NightlyVitalsFetch {
        let json = try await getJSON(path: "/core-details-bff/v0/cycles/details", query: [
            "id": userID, "startTime": Self.isoString(start), "endTime": Self.isoString(end), "limit": "50"
        ])
        return NightlyVitalsFetch(readings: WhoopNightlyVitalsAdapter.readings(fromCyclesJSON: json),
                                  fieldNames: WhoopNightlyVitalsAdapter.fieldNames(fromCyclesJSON: json))
    }

    func fetchCurrentUser() async throws -> WhoopUser {
        let json = try await getJSON(path: "/auth-service/v2/user", query: [:])
        let userID = try WhoopPayloadAdapters.userID(from: json)
        return WhoopUser(id: userID)
    }

    func fetchSleepActivities(userID: String, start: Date, end: Date) async throws -> [WhoopSleepActivity] {
        do {
            let json = try await getJSON(
                path: "/core-details-bff/v0/cycles/details",
                query: [
                    "id": userID,
                    "startTime": Self.isoString(start),
                    "endTime": Self.isoString(end),
                    "limit": "50"
                ]
            )
            let activities = WhoopPayloadAdapters.sleepActivities(fromCyclesJSON: json)
            if !activities.isEmpty {
                return activities
            }
            AppLog.api.info("Cycles details returned no sleep activities; trying deep-dive sleep fallback.")
            return try await fetchDeepDiveSleepActivities(start: start, end: end)
        } catch {
            guard Self.shouldFallbackToDeepDiveSleep(for: error) else {
                throw error
            }
            AppLog.api.warning("Cycles details sleep discovery failed with fallback-compatible error; trying deep-dive sleep fallback.")
            return try await fetchDeepDiveSleepActivities(start: start, end: end)
        }
    }

    func fetchSleepSession(activity: WhoopSleepActivity) async throws -> SleepSession {
        if let date = deepDiveDate(fromActivityID: activity.activityID) {
            if let cached = deepDiveSleepSessionCache[date] {
                deepDiveSleepSessionCache.removeValue(forKey: date)
                return cached
            }
            return try await fetchDeepDiveSleepSession(date: date)
        }

        let json = try await getJSON(
            path: "/sleep-service/v1/sleep-events",
            query: [
                "activityId": activity.activityID
            ]
        )
        return try WhoopPayloadAdapters.sleepSession(
            fromSleepEventsJSON: json,
            activity: activity
        )
    }

    private func fetchDeepDiveSleepActivities(start: Date, end: Date) async throws -> [WhoopSleepActivity] {
        var activities: [WhoopSleepActivity] = []
        for date in Self.localDateStrings(from: start, to: end) {
            do {
                let session = try await fetchDeepDiveSleepSession(date: date)
                activities.append(
                    WhoopSleepActivity(
                        activityID: "\(deepDiveActivityPrefix)\(date)",
                        sourceUpdatedAt: session.sourceUpdatedAt,
                        isNap: session.isNap
                    )
                )
            } catch {
                if Self.isExpectedMissingDeepDiveSleep(error) {
                    AppLog.api.info("No deep-dive sleep payload for \(date, privacy: .public).")
                    continue
                }
                throw error
            }
        }
        return activities
    }

    private func fetchDeepDiveSleepSession(date: String) async throws -> SleepSession {
        let activityID = "\(deepDiveActivityPrefix)\(date)"
        let json = try await getJSON(
            path: "/home-service/v1/deep-dive/sleep",
            query: [
                "date": date
            ]
        )
        let session = try WhoopPayloadAdapters.sleepSession(
            fromSleepEventsJSON: json,
            activity: WhoopSleepActivity(
                activityID: activityID,
                sourceUpdatedAt: nil,
                isNap: false
            )
        )
        deepDiveSleepSessionCache[date] = session
        return session
    }

    func fetchHeartRate(userID: String, start: Date, end: Date, stepSeconds: Int) async throws -> [HeartRatePoint] {
        let json = try await getJSON(
            path: "/metrics-service/v1/metrics/user/\(userID)",
            query: [
                "start": Self.isoString(start),
                "end": Self.isoString(end),
                "step": "\(stepSeconds)",
                "name": "heart_rate"
            ]
        )
        return try WhoopPayloadAdapters.heartRatePoints(fromJSON: json, stepSeconds: stepSeconds)
    }

    private func getJSON(path: String, query: [String: String], allowRefresh: Bool = true, recoveryRequest: Bool = false) async throws -> Any {
        let token = try await auth.validAccessToken()
        var request = try makeRequest(path: path, query: query, token: token)

        let start = Date()
        let (data, response) = try await session.data(for: request)
        let elapsed = Date().timeIntervalSince(start)
        guard let http = response as? HTTPURLResponse else {
            throw WhoopAPIError.invalidHTTPResponse
        }

        AppLog.api.info("GET \(path, privacy: .public) status=\(http.statusCode) elapsed=\(elapsed, privacy: .public)")
        if Self.shouldRefreshAccessToken(afterStatus: http.statusCode), allowRefresh {
            AppLog.api.warning("WHOOP request returned \(http.statusCode, privacy: .public); refreshing token once.")
            let refreshed = try await auth.refresh()
            request = try makeRequest(path: path, query: query, token: refreshed.accessToken)
            let (retryData, retryResponse) = try await session.data(for: request)
            guard let retryHTTP = retryResponse as? HTTPURLResponse else {
                throw WhoopAPIError.invalidHTTPResponse
            }
            if recoveryRequest, retryHTTP.statusCode == 429 { throw recoveryRateLimit(retryHTTP) }
            guard (200..<300).contains(retryHTTP.statusCode) else {
                throw WhoopAPIError.http(status: retryHTTP.statusCode, path: path, message: Self.sanitizedMessage(from: retryData))
            }
            return try Self.parseJSON(retryData)
        }

        if recoveryRequest, http.statusCode == 429 { throw recoveryRateLimit(http) }
        guard (200..<300).contains(http.statusCode) else {
            throw WhoopAPIError.http(status: http.statusCode, path: path, message: Self.sanitizedMessage(from: data))
        }
        return try Self.parseJSON(data)
    }

    private func recoveryRateLimit(_ response: HTTPURLResponse) -> RecoverySyncError {
        let raw = response.value(forHTTPHeaderField: "Retry-After") ?? ""
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let date = Double(raw).flatMap { $0.isFinite && $0 >= 0 ? Date().addingTimeInterval($0) : nil }
            ?? formatter.date(from: raw) ?? Date().addingTimeInterval(60)
        recoveryRetryNotBefore = max(Date(), date)
        return .rateLimited(until: recoveryRetryNotBefore!)
    }

    private func makeRequest(path: String, query: [String: String], token: String) throws -> URLRequest {
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let url = cleanPath
            .split(separator: "/")
            .reduce(configuration.baseURL) { partial, component in
                partial.appendingPathComponent(String(component))
            }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw WhoopAPIError.invalidURL(path)
        }
        components.queryItems = query.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        guard let url = components.url else {
            throw WhoopAPIError.invalidURL(path)
        }

        var request = URLRequest(url: url, timeoutInterval: configuration.requestTimeoutSeconds)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("HealthDataBridge/0.2.0", forHTTPHeaderField: "User-Agent")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "x-whoop-time-zone")
        request.setValue(Locale.current.identifier, forHTTPHeaderField: "locale")
        return request
    }

    private static func shouldRefreshAccessToken(afterStatus status: Int) -> Bool {
        status == 401 || status == 403
    }

    private static func parseJSON(_ data: Data) throws -> Any {
        guard !data.isEmpty else {
            return [:]
        }
        return try JSONSerialization.jsonObject(with: data, options: [])
    }

    private static func sanitizedMessage(from data: Data) -> String {
        guard !data.isEmpty else { return "empty response" }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let message = object["error_description"] as? String
                ?? object["error"] as? String
                ?? object["message"] as? String
                ?? "JSON error body"
            return SensitiveTextSanitizer.redact(message)
        }
        return "non-JSON error body"
    }

    static func isoString(_ date: Date) -> String {
        WhoopDateCodec.isoString(date)
    }

    private func deepDiveDate(fromActivityID activityID: String) -> String? {
        guard activityID.hasPrefix(deepDiveActivityPrefix) else {
            return nil
        }
        return String(activityID.dropFirst(deepDiveActivityPrefix.count))
    }

    private static func shouldFallbackToDeepDiveSleep(for error: Error) -> Bool {
        guard let apiError = error as? WhoopAPIError else {
            return false
        }
        switch apiError {
        case let .http(status, _, _):
            return [400, 404, 422].contains(status)
        case .invalidURL, .invalidHTTPResponse:
            return false
        }
    }

    private static func isExpectedMissingDeepDiveSleep(_ error: Error) -> Bool {
        // A night without the strap worn comes back as an empty sleep payload rather than a 404.
        if let payloadError = error as? WhoopPayloadError {
            return payloadError == .missingField("sleep events")
        }
        guard let apiError = error as? WhoopAPIError else {
            return false
        }
        switch apiError {
        case let .http(status, _, _):
            return status == 404
        case .invalidURL, .invalidHTTPResponse:
            return false
        }
    }

    private static func localDateStrings(from start: Date, to end: Date) -> [String] {
        guard start < end else {
            return []
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        var dates: [String] = []
        var cursor = calendar.startOfDay(for: start)
        let formatter = localDateFormatter()

        while cursor < end {
            dates.append(formatter.string(from: cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else {
                break
            }
            cursor = next
        }
        return dates
    }

    private static func localDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

enum WhoopAPIError: Error, LocalizedError {
    case invalidURL(String)
    case invalidHTTPResponse
    case http(status: Int, path: String, message: String)

    var errorDescription: String? {
        switch self {
        case let .invalidURL(path):
            return "Invalid WHOOP API URL for \(path)."
        case .invalidHTTPResponse:
            return "WHOOP API did not return an HTTP response."
        case let .http(status, path, message):
            return "WHOOP API \(path) failed (\(status)): \(message)"
        }
    }
}
