import Foundation
import CoreFoundation

/// Read-only structural diagnostics: no scalar values, account IDs, health values or payload excerpts.
public enum WhoopContractProbe {
    public static func schema(of value: Any, maxEntries: Int = 400) -> String {
        var lines: [String] = []
        func inspect(_ object: Any, path: String, depth: Int) {
            guard lines.count < maxEntries, depth < 9 else { return }
            if let dictionary = object as? [String: Any] {
                lines.append("\(path): object")
                for key in dictionary.keys.sorted() {
                    guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil else { continue }
                    inspect(dictionary[key]!, path: "\(path).\(key)", depth: depth + 1)
                }
            } else if let array = object as? [Any] {
                lines.append("\(path): array")
                for child in array.prefix(3) { inspect(child, path: "\(path)[]", depth: depth + 1) }
            } else if object is NSNull { lines.append("\(path): null") }
            else if object is String { lines.append("\(path): string") }
            else if object is NSNumber { lines.append("\(path): number-or-boolean") }
            else { lines.append("\(path): unknown") }
        }
        inspect(value, path: "$", depth: 0)
        return Array(Set(lines)).sorted().joined(separator: "\n")
    }
}

/// Explicitly requested, in-memory diagnostic. Never returns IDs, tokens, arbitrary payloads or cursors.
/// Unit conversion is based on seven real UI/API comparisons on 2026-09-15, not field-name inference.
public enum WhoopRecoveryValueProbe {
    public static func report(of json: Any, expectedUserID: String, maxRows: Int = 20) -> String {
        guard let root = json as? [String: Any], let records = root["records"] as? [Any] else {
            return "Contrato: falta records[]; no se puede comparar."
        }
        var lines = ["Registros recibidos: \(records.count). HRV_API en segundos; HRV_ms = HRV_API × 1000, sin redondear."]
        for key in ["next_token", "nextToken", "next_cursor", "nextCursor", "next", "has_more", "hasMore", "total_count", "total"] where root[key] != nil {
            let value = root[key]!
            let status = value is NSNull ? "null" : (flag(value).map { $0 ? "true" : "false" } ?? "presente (valor oculto)")
            lines.append("Paginación \(key): \(status)")
        }
        if !root.keys.contains(where: { ["next_token", "nextToken", "next_cursor", "nextCursor", "next", "has_more", "hasMore", "total_count", "total"].contains($0) }) {
            lines.append("Sin señal de fin/paginación reconocida. Una ventana vacía no demuestra fin del histórico.")
        }
        let boundedRows = max(0, min(maxRows, 50))
        for (index, raw) in records.prefix(boundedRows).enumerated() {
            guard let record = raw as? [String: Any], let recovery = record["recovery"] as? [String: Any] else {
                lines.append("Fila \(index + 1): sin recuperación reconocida."); continue
            }
            let cycle = record["cycle"] as? [String: Any] ?? [:]
            let userMatches = numericID(cycle["user_id"]) == expectedUserID && numericID(recovery["user_id"]) == expectedUserID
            let cycleIDValid = numericID(cycle["id"]) != nil
            let activity = recovery["activity_id"] as? String
            let sleeps = (record["sleeps"] as? [[String: Any]] ?? []).filter {
                guard let activity, !activity.isEmpty else { return false }
                return $0["activity_id"] as? String == activity
            }
            let sleep = sleeps.count == 1 ? sleeps[0] : [:]
            let range = WhoopPayloadAdapters.timeRange(from: sleep["during"])
            let zone = timeZone(sleep["timezone_offset"] ?? cycle["timezone_offset"])
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"; formatter.timeZone = zone ?? TimeZone(secondsFromGMT: 0)!
            let end = range.map { formatter.string(from: $0.end) } ?? "no reconocido"
            let start = range.map { formatter.string(from: $0.start) } ?? "no reconocido"
            let value = number(recovery["hrv_rmssd"])
            let valueText = value.map { String($0) } ?? "inválido/nulo (booleanos rechazados)"
            let milliseconds = value.map { $0 * 1000 }.flatMap { $0.isFinite ? String($0) : nil } ?? "inválido/nulo"
            let nap = flag(sleep["is_nap"]).map { $0 ? "sí" : "no" } ?? "desconocida"
            let calibration = flag(recovery["calibrating"]).map { $0 ? "sí" : "no" } ?? "desconocida"
            let state = enumLabel(recovery["state"])
            let update = WhoopDateCodec.date(from: recovery["updated_at"]).map { formatter.string(from: $0) } ?? "no reconocida"
            lines.append("Fila \(index + 1): cuenta=\(userMatches ? "coincide" : "NO VERIFICADA"); ciclo_ID=\(cycleIDValid ? "válido" : "inválido"); enlace_sueño=\(sleeps.count == 1 ? "único" : "ausente/ambiguo"); zona=\(zone == nil ? "NO RECONOCIDA (fechas UTC)" : "offset reconocido")")
            lines.append("inicio=\(start); fin=\(end); siesta=\(nap); HRV_API=\(valueText); HRV_ms=\(milliseconds); estado=\(state); calibrando=\(calibration); actualización=\(update)")
        }
        if records.count > boundedRows { lines.append("Salida limitada a \(boundedRows) filas; no es una enumeración completa.") }
        return lines.joined(separator: "\n")
    }
    private static func number(_ raw: Any?) -> Double? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue > 0 else { return nil }
        return n.doubleValue
    }
    private static func numericID(_ raw: Any?) -> String? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
              n.doubleValue > 0, n.doubleValue.rounded(.towardZero) == n.doubleValue else { return nil }
        return n.stringValue
    }
    private static func flag(_ raw: Any?) -> Bool? {
        guard let n = raw as? NSNumber else { return nil }
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        if n.doubleValue == 0 { return false }; if n.doubleValue == 1 { return true }; return nil
    }
    private static func enumLabel(_ raw: Any?) -> String {
        guard let s = raw as? String, s.range(of: "^[A-Za-z_]{1,32}$", options: .regularExpression) != nil else { return "no reconocido (valor oculto)" }
        return s
    }
    private static func timeZone(_ raw: Any?) -> TimeZone? {
        guard let s = raw as? String, s.range(of: "^[+-][0-9]{2}:?[0-9]{2}$", options: .regularExpression) != nil else { return nil }
        let digits = String(s.dropFirst()).replacingOccurrences(of: ":", with: "")
        guard let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)), hours <= 14, minutes < 60,
              hours < 14 || minutes == 0 else { return nil }
        return TimeZone(secondsFromGMT: (s.first == "-" ? -1 : 1) * (hours * 3600 + minutes * 60))
    }
}
