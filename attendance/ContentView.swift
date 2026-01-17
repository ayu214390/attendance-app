//  ContentView.swift
//  attendance (iOS / macOS 共通)
//  This source code is published as a demo / portfolio version.
//  It does NOT contain real shop data or personal information.

import SwiftUI
import CryptoKit
import Security
import UniformTypeIdentifiers
import AuthenticationServices
import LocalAuthentication
#if os(macOS)
import AppKit
#endif

// MARK: - Model
struct Staff: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var hourlyWageYen: Int? = nil
    var mealAllowanceYen: Int? = nil
}

struct AttendanceRecord: Identifiable, Codable {
    let id: UUID
    let staffId: UUID
    var date: Date
    var clockIn: Date?
    var clockOut: Date?
    var breakStart: Date?
    var breakMinutes: Int
    var mealCount: Int = 0
    
    var isOnBreak: Bool { breakStart != nil }
    var totalSecondsWorked: TimeInterval? {
        guard let ci = clockIn, let co = clockOut else { return nil }
        let raw = co.timeIntervalSince(ci)
        let breakSec = TimeInterval(max(0, breakMinutes) * 60)
        return max(0, raw - breakSec)
    }
    
    private enum CodingKeys: String, CodingKey {
        case id, staffId, date, clockIn, clockOut, breakStart, breakMinutes, mealCount
    }
    
    init(id: UUID, staffId: UUID, date: Date, clockIn: Date?, clockOut: Date?, breakStart: Date?, breakMinutes: Int, mealCount: Int = 0) {
        self.id = id
        self.staffId = staffId
        self.date = date
        self.clockIn = clockIn
        self.clockOut = clockOut
        self.breakStart = breakStart
        self.breakMinutes = breakMinutes
        self.mealCount = mealCount
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        staffId = try c.decode(UUID.self, forKey: .staffId)
        date = try c.decode(Date.self, forKey: .date)
        clockIn = try c.decodeIfPresent(Date.self, forKey: .clockIn)
        clockOut = try c.decodeIfPresent(Date.self, forKey: .clockOut)
        breakStart = try c.decodeIfPresent(Date.self, forKey: .breakStart)
        breakMinutes = try c.decode(Int.self, forKey: .breakMinutes)
        mealCount = try c.decodeIfPresent(Int.self, forKey: .mealCount) ?? 0
    }
}


// MARK: - Rounding
enum RoundingMode: String, CaseIterable, Codable {
    case minute1, quarter15
    var label: String { self == .minute1 ? "1分単位" : "15分丸め" }
}

// MARK: - Current User Namespace
fileprivate enum CurrentUserStore {
    private static let key = "current_user_id_v1"
    static func setCurrent(_ id: String?) {
        let ud = UserDefaults.standard
        if let id, !id.isEmpty {
            ud.set(id, forKey: key)
        } else {
            ud.removeObject(forKey: key)
        }
    }
    static func load() -> String? {
        UserDefaults.standard.string(forKey: key)
    }
}

// MARK: - Persistence (Namespaced by current user)
final class AttendanceManager: ObservableObject {
    @Published var staffs: [Staff] = [] { didSet { save() } }
    @Published var lastBackupMessage: String? = nil
    @Published private(set) var records: [String: AttendanceRecord] = [:] { didSet { save() } } // key = day+staffId
    @Published private var lastAutoBackupDate: Date? = UserDefaults.standard.object(forKey: "lastAutoBackupDate") as? Date
    /// アプリ起動時・復帰時に呼ばれる自動バックアップチェック
    func checkAndAutoBackup() {
        let now = Date()
        let cal = Calendar.current
        // 今日の0:00
        let today = cal.startOfDay(for: now)
        
        // 前回バックアップがなければ即バックアップ
        guard let last = lastAutoBackupDate else {
            backupToFile()
            lastAutoBackupDate = today
            UserDefaults.standard.set(today, forKey: "lastAutoBackupDate")
            return
        }
        
        // もし0:00を跨いでいたら新しいバックアップを作成
        if cal.compare(today, to: last, toGranularity: .day) == .orderedDescending {
            backupToFile()
            lastAutoBackupDate = today
            UserDefaults.standard.set(today, forKey: "lastAutoBackupDate")
        }
    }
    
    
    // namespace = 短いハッシュ（userId から作成） or "default"
    private var namespace: String = "default"
    private static func ns(from userId: String?) -> String {
        guard let id = userId, !id.isEmpty else { return "default" }
        let hex = sha256Hex(id)
        return String(hex.prefix(12))
    }
    private var keyStaff: String { "att_staffs_v1_\(namespace)" }
    private var keyRecords: String { "att_records_v1_\(namespace)" }
    
    // --- Namespace-aware raw IO helpers ---
    private func rawLoad(namespace ns: String) -> (staffs: [Staff], records: [String: AttendanceRecord])? {
        let ud = UserDefaults.standard
        let ks = "att_staffs_v1_\(ns)"
        let kr = "att_records_v1_\(ns)"
        guard let ds = ud.data(forKey: ks), let dr = ud.data(forKey: kr) else { return nil }
        let decoder = JSONDecoder()
        guard let s = try? decoder.decode([Staff].self, from: ds),
              let r = try? decoder.decode([String: AttendanceRecord].self, from: dr) else { return nil }
        return (s, r)
    }
    // MARK: - Backup & Restore (Date-Stamped)
    /// Documentsディレクトリ内のURLを取得
    private func documentsURL(_ fileName: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }
    /// バックアップデータの構造体
    struct BackupData: Codable {
        var staffs: [Staff]
        var records: [String: AttendanceRecord]
    }
    /// 日付付きバックアップの作成
    func backupToFile() {
        let backup = BackupData(staffs: staffs, records: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dateString = df.string(from: Date())
        let fileName = "backup_\(dateString).json"
        let url = documentsURL(fileName)
        do {
            let data = try encoder.encode(backup)
            try data.write(to: url)
            print("✅ Backup saved to: \(url.path)")
            lastBackupMessage = "✅ バックアップを保存しました（\(fileName)）"
        } catch {
            print("⚠️ Backup failed:", error)
            lastBackupMessage = "⚠️ バックアップに失敗しました: \(error.localizedDescription)"
        }
    }
    /// 最新のバックアップを探して復元
    func restoreLatestBackup() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            let jsonFiles = files.filter { $0.lastPathComponent.hasPrefix("backup_") && $0.pathExtension == "json" }
            guard let latest = jsonFiles.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first else {
                print("⚠️ No backup files found.")
                lastBackupMessage = "⚠️ バックアップファイルが見つかりません。"
                return
            }
            let data = try Data(contentsOf: latest)
            let backup = try JSONDecoder().decode(BackupData.self, from: data)
            self.staffs = backup.staffs
            self.records = backup.records
            print("✅ Restored from: \(latest.lastPathComponent)")
            lastBackupMessage = "✅ 復元に成功しました（\(latest.lastPathComponent)）"
        } catch {
            print("⚠️ Restore failed:", error)
            lastBackupMessage = "⚠️ 復元に失敗しました: \(error.localizedDescription)"
        }
    }
    private func migrateFromDefaultIfNeeded() {
        // If current namespace has no data but default has, migrate once.
        guard self.namespace != "default" else { return }
        let hasCurrent = !(self.staffs.isEmpty && self.records.isEmpty)
        guard !hasCurrent else { return }
        if let payload = rawLoad(namespace: "default"), !(payload.staffs.isEmpty && payload.records.isEmpty) {
            self.staffs = payload.staffs
            self.records = payload.records
            save() // persist under the current namespace keys
        }
    }
    
    init() {
        // 起動時の現在ユーザー（ログイン前なら nil → "default"）
        self.namespace = AttendanceManager.ns(from: CurrentUserStore.load())
        load()
        if staffs.isEmpty {
            staffs = ["Alice", "Bob", "Charlie"].map { Staff(id: UUID(), name: $0) }
        }
        // もし default 名義に過去データが残っているなら、現在の名前空間へ一度だけ取り込む
        migrateFromDefaultIfNeeded()
    }
    func switchUser(_ userId: String?) {
        let newNS = AttendanceManager.ns(from: userId)
        guard newNS != self.namespace else { return }
        self.namespace = newNS
        load()
        if staffs.isEmpty {
            staffs = ["Alice", "Bob", "Charlie"].map { Staff(id: UUID(), name: $0) }
        }
        migrateFromDefaultIfNeeded()
    }
    
    private func load() {
        let ud = UserDefaults.standard
        if let d = ud.data(forKey: keyStaff), let s = try? JSONDecoder().decode([Staff].self, from: d) { staffs = s } else { staffs = [] }
        if let d = ud.data(forKey: keyRecords), let r = try? JSONDecoder().decode([String: AttendanceRecord].self, from: d) { records = r } else { records = [:] }
        normalizeRecordKeysIfNeeded()
    }
    
    
    // 旧キー「<timestamp>_<uuid>」を「yyyy-MM-dd_<uuid>」に移行
    private func normalizeRecordKeysIfNeeded() {
        var changed = false
        var newRecords: [String: AttendanceRecord] = [:]
        for (k, v) in records {
            // 例: "1738713600.0_XXXXXXXX-...."
            let parts = k.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count == 2, let ts = Double(parts[0]) {
                // timestamp から日付へ
                let day = Date(timeIntervalSince1970: ts)
                let newKey = dayKey(day, staffId: v.staffId)
                newRecords[newKey] = v
                changed = true
            } else {
                newRecords[k] = v
            }
        }
        if changed {
            records = newRecords
            // didSetでsave()が呼ばれる
        }
    }
    
    private func save() {
        let ud = UserDefaults.standard
        if let d = try? JSONEncoder().encode(staffs) { ud.set(d, forKey: keyStaff) }
        if let d = try? JSONEncoder().encode(records) { ud.set(d, forKey: keyRecords) }
    }
    // 安定キー: yyyy-MM-dd + staffId
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "ja_JP_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    
    private func dayKey(_ date: Date, staffId: UUID) -> String {
        let day = Calendar.current.startOfDay(for: date)
        let dstr = AttendanceManager.dayKeyFormatter.string(from: day)
        return "\(dstr)_\(staffId.uuidString)"
    }
    private func todayKey(for staffId: UUID) -> String { dayKey(Date(), staffId: staffId) }
    
    func record(for staff: Staff) -> AttendanceRecord {
        let key = todayKey(for: staff.id)
        if let r = records[key] { return r }
        // View構築中は保存しない一時オブジェクトを返す
        return AttendanceRecord(id: UUID(), staffId: staff.id, date: Calendar.current.startOfDay(for: Date()), clockIn: nil, clockOut: nil, breakStart: nil, breakMinutes: 0, mealCount: 0)
    }
    func record(for staff: Staff, on date: Date) -> AttendanceRecord {
        let k = dayKey(date, staffId: staff.id)
        if let r = records[k] { return r }
        let r = AttendanceRecord(id: UUID(), staffId: staff.id, date: Calendar.current.startOfDay(for: date), clockIn: nil, clockOut: nil, breakStart: nil, breakMinutes: 0, mealCount: 0)
        records[k] = r
        return r
    }
    func updateRecord(staff: Staff, on date: Date, clockIn: Date?, clockOut: Date?, breakMinutes: Int, mealCount: Int? = nil) {
        let k = dayKey(date, staffId: staff.id)
        var r = record(for: staff, on: date)
        r.clockIn = clockIn
        r.clockOut = clockOut
        r.breakStart = nil
        r.breakMinutes = max(0, breakMinutes)
        if let mc = mealCount { r.mealCount = max(0, mc) }
        records[k] = r
    }
    // Actions
    func clockIn(_ staff: Staff) {
        let k = todayKey(for: staff.id); var r = record(for: staff)
        guard r.clockIn == nil else { return }
        r.clockIn = Date(); r.clockOut = nil
        records[k] = r
    }
    func clockOut(_ staff: Staff) {
        let k = todayKey(for: staff.id); var r = record(for: staff)
        guard r.clockIn != nil else { return }
        if let start = r.breakStart {
            let minutes = Int(Date().timeIntervalSince(start) / 60)
            r.breakMinutes = max(0, r.breakMinutes + minutes)
            r.breakStart = nil
        }
        r.clockOut = Date(); records[k] = r
    }
    func breakStart(_ staff: Staff) {
        let k = todayKey(for: staff.id); var r = record(for: staff)
        guard r.clockIn != nil, r.breakStart == nil else { return }
        r.breakStart = Date(); records[k] = r
    }
    func breakEnd(_ staff: Staff) {
        let k = todayKey(for: staff.id); var r = record(for: staff)
        guard let start = r.breakStart else { return }
        let minutes = Int(Date().timeIntervalSince(start) / 60)
        r.breakMinutes = max(0, r.breakMinutes + minutes)
        r.breakStart = nil; records[k] = r
    }
    func addMeal(_ staff: Staff) {
        let k = todayKey(for: staff.id); var r = record(for: staff)
        r.mealCount += 1; records[k] = r
    }
    // Staff ops
    func addStaff(name: String) { staffs.append(.init(id: UUID(), name: name)) }
    func rename(_ staff: Staff, to name: String) { if let i = staffs.firstIndex(of: staff) { staffs[i].name = name } }
    func remove(_ staff: Staff) {
        staffs.removeAll { $0.id == staff.id }
        records = records.filter { $0.value.staffId != staff.id }
    }
    func setHourlyWage(_ yen: Int?, for staff: Staff) { if let i = staffs.firstIndex(of: staff) { staffs[i].hourlyWageYen = yen } }
    func setMealAllowance(_ yen: Int?, for staff: Staff) { if let i = staffs.firstIndex(of: staff) { staffs[i].mealAllowanceYen = yen } }
    
    
    // Payroll helpers
    func monthlyTotalHours(for staff: Staff, month: Date, rounding: RoundingMode) -> Double {
        let cal = Calendar.current
        guard let start = cal.date(from: cal.dateComponents([.year, .month], from: month)),
              let end = cal.date(byAdding: DateComponents(month: 1), to: start) else { return 0 }
        let startDay = cal.startOfDay(for: start)
        let endDay = cal.startOfDay(for: end)
        var totalMinutes: Double = 0
        for r in records.values where r.staffId == staff.id {
            let d = cal.startOfDay(for: r.date)
            guard d >= startDay && d < endDay, let secs = r.totalSecondsWorked else { continue }
            switch rounding {
            case .minute1:
                totalMinutes += max(0, (secs/60).rounded())
            case .quarter15:
                let mins = secs / 60
                // 出勤は切り上げ、退勤は切り下げに見立てて「総労働時間」を計算
                // ⇒ 分単位で15分ごとに丸め（8分未満は切り下げ、8分以上は切り上げ）
                let remainder = mins.truncatingRemainder(dividingBy: 15)
                if remainder >= 7.5 {
                    totalMinutes += (mins - remainder + 15)
                } else {
                    totalMinutes += (mins - remainder)
                }
            }
        }
        return totalMinutes / 60.0
    }
    func monthlyMealCount(for staff: Staff, month: Date) -> Int {
        let cal = Calendar.current
        guard let start = cal.date(from: cal.dateComponents([.year, .month], from: month)),
              let end = cal.date(byAdding: DateComponents(month: 1), to: start) else { return 0 }
        let startDay = cal.startOfDay(for: start)
        let endDay = cal.startOfDay(for: end)
        return records.values
            .filter { $0.staffId == staff.id }
            .filter { let d = cal.startOfDay(for: $0.date); return d >= startDay && d < endDay }
            .reduce(0) { $0 + max(0, $1.mealCount) }
    }
    func monthlyDailyRecords(for staff: Staff, month: Date) -> [AttendanceRecord] {
        let cal = Calendar.current
        guard let start = cal.date(from: cal.dateComponents([.year, .month], from: month)),
              let end = cal.date(byAdding: DateComponents(month: 1), to: start) else { return [] }
        let startDay = cal.startOfDay(for: start)
        let endDay = cal.startOfDay(for: end)
        return records.values
            .filter { $0.staffId == staff.id }
            .filter { let d = cal.startOfDay(for: $0.date); return d >= startDay && d < endDay }
            .sorted { $0.date < $1.date }
    }
}

// MARK: - Keychain (Owner PW)
enum Keychain {
    static let service = "attendance.owner"
    static let account = "owner_password_hash"
    static func save(hash: Data) -> Bool {
        _ = delete()
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecValueData as String: hash]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
    static func load() -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true]
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecSuccess { return (out as? Data) }
        return nil
    }
    static func delete() -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        let st = SecItemDelete(q as CFDictionary)
        return st == errSecSuccess || st == errSecItemNotFound
    }
}

// MARK: - Keychain (Auth user id)
enum KeychainAuth {
    static let service = "attendance.auth"
    static let appleAccount = "apple_user_id"
    static func saveAppleUserId(_ id: String) -> Bool {
        guard let data = id.data(using: .utf8) else { return false }
        _ = deleteAppleUserId()
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: appleAccount,
                                kSecValueData as String: data]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
    static func loadAppleUserId() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: appleAccount,
                                kSecReturnData as String: true]
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecSuccess, let data = out as? Data { return String(data: data, encoding: .utf8) }
        return nil
    }
    static func deleteAppleUserId() -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: appleAccount]
        let st = SecItemDelete(q as CFDictionary)
        return st == errSecSuccess || st == errSecItemNotFound
    }
}

// MARK: - Local ID/PASS Store (UserDefaults)

fileprivate enum AccountsError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let s): return s
        }
    }
}
fileprivate enum AccountsStore {
    private static let key = "local_accounts_v1" // [id: sha256Hex(pass)]
    
    private static func load() -> [String: String] {
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: key),
           let dict = try? JSONDecoder().decode([String:String].self, from: data) { return dict }
        return [:]
    }
    private static func save(_ dict: [String:String]) {
        if let data = try? JSONEncoder().encode(dict) { UserDefaults.standard.set(data, forKey: key) }
    }
    static func register(id: String, password: String) -> Result<Void, AccountsError> {
        let trimmedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else { return .failure(.message("IDを入力してください")) }
        guard password.count >= 4 else { return .failure(.message("パスワードは4文字以上にしてください")) }
        var dict = load()
        guard dict[trimmedId] == nil else { return .failure(.message("このIDは既に使われています")) }
        dict[trimmedId] = sha256Hex(password)
        save(dict)
        return .success(())
    }
    static func verify(id: String, password: String) -> Bool {
        let dict = load()
        guard let stored = dict[id] else { return false }
        return stored == sha256Hex(password)
    }
    static func exists(id: String) -> Bool {
        let dict = load()
        return dict.keys.contains(id)
    }
    static func setPassword(id: String, password: String) -> Result<Void, AccountsError> {
        var dict = load()
        guard dict[id] != nil else { return .failure(.message("そのIDは登録されていません")) }
        dict[id] = sha256Hex(password)
        save(dict)
        return .success(())
    }
}

fileprivate func sha256Hex(_ text: String) -> String {
    let digest = sha256(text)
    return digest.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Owner Profile Store (UserDefaults)
// NOTE:
// OwnerProfile is for demo purposes only.
// Do not store real personal information in public builds.
fileprivate struct OwnerProfile: Codable {
    var ownerName: String
    var companyName: String
    var birthDateISO8601: String // "yyyy-MM-dd"
}

fileprivate enum OwnerProfileStore {
    private static let key = "owner_profile_v1"
    static func load() -> OwnerProfile? {
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: key) {
            return try? JSONDecoder().decode(OwnerProfile.self, from: data)
        }
        return nil
    }
    static func save(_ profile: OwnerProfile) {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

fileprivate func isoDateString(_ date: Date) -> String {
    let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian)
    f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "ja_JP_POSIX"); f.timeZone = .current
    return f.string(from: date)
}

func sha256(_ text: String) -> Data { Data(SHA256.hash(data: text.data(using: .utf8)!)) }
func isStrongPassword(_ p: String) -> Bool {
    guard p.count >= 8 else { return false }
    let letter = p.range(of: "[A-Za-z]", options: .regularExpression) != nil
    let digit = p.range(of: "[0-9]", options: .regularExpression) != nil
    let symbol = p.range(of: "[^A-Za-z0-9]", options: .regularExpression) != nil
    return letter && digit && symbol
}

// MARK: - Biometric Auth Helper
fileprivate enum BiometricAuth {
    static func canEvaluate() -> (ok: Bool, type: LABiometryType) {
        let ctx = LAContext()
        var err: NSError?
        let ok = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
        return (ok, ctx.biometryType)
    }
    static func authenticate(reason: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "パスコード"
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, error in
            DispatchQueue.main.async {
                if success { completion(.success(())) }
                else { completion(.failure(error ?? NSError(domain: "Bio", code: -1, userInfo: [NSLocalizedDescriptionKey: "認証に失敗しました"])) ) }
            }
        }
    }
}

// MARK: - Auth (Apple ID)
final class AuthState: ObservableObject {
    @Published var userId: String? = nil
    init() {
        self.userId = KeychainAuth.loadAppleUserId()
        // 既にAppleIDがKeychainにあれば current user にも反映
        if let id = self.userId { CurrentUserStore.setCurrent(id) }
    }
    func signOut() {
        _ = KeychainAuth.deleteAppleUserId()
        self.userId = nil
        CurrentUserStore.setCurrent(nil)
    }
}

// Apple Sign-in（安定版）
final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    let onComplete: (Result<String, Error>) -> Void
    init(onComplete: @escaping (Result<String, Error>) -> Void) { self.onComplete = onComplete }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
#if os(iOS)
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
           let window = scene.windows.first(where: { $0.isKeyWindow }) { return window }
        return UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows.first }.first ?? UIWindow()
#elseif os(macOS)
        return NSApplication.shared.windows.first { $0.isKeyWindow } ?? NSWindow()
#else
        return ASPresentationAnchor()
#endif
    }
    func signIn() {
        let p = ASAuthorizationAppleIDProvider().createRequest()
        p.requestedScopes = [.fullName, .email]
        let c = ASAuthorizationController(authorizationRequests: [p])
        c.delegate = self; c.presentationContextProvider = self; c.performRequests()
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        if let cred = authorization.credential as? ASAuthorizationAppleIDCredential {
            onComplete(.success(cred.user))
        } else {
            onComplete(.failure(NSError(domain: "AppleSignIn", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid credential"])))
        }
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) { onComplete(.failure(error)) }
}

struct AppleIDButtonRepresentable: View {
    let action: () -> Void
    var body: some View {
#if os(iOS)
        RepresentableIOS(action: action).frame(height: 50)
#else
        RepresentableMac(action: action).frame(width: 220, height: 44)
#endif
    }
#if os(iOS)
    struct RepresentableIOS: UIViewRepresentable {
        let action: () -> Void
        func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
            let v = ASAuthorizationAppleIDButton(type: .signIn, style: .black)
            v.addTarget(context.coordinator, action: #selector(Coordinator.tap), for: .touchUpInside)
            return v
        }
        func updateUIView(_ uiView: ASAuthorizationAppleIDButton, context: Context) {}
        func makeCoordinator() -> Coordinator { Coordinator(action: action) }
        final class Coordinator: NSObject {
            let action: () -> Void
            init(action: @escaping () -> Void) {
                self.action = action
            }
            @objc func tap() { action() }
        }
    }
#endif
#if os(macOS)
    struct RepresentableMac: NSViewRepresentable {
        let action: () -> Void
        func makeNSView(context: Context) -> ASAuthorizationAppleIDButton {
            let v = ASAuthorizationAppleIDButton(authorizationButtonType: .signIn, authorizationButtonStyle: .black)
            v.target = context.coordinator; v.action = #selector(Coordinator.tap); return v
        }
        func updateNSView(_ nsView: ASAuthorizationAppleIDButton, context: Context) {}
        func makeCoordinator() -> Coordinator { Coordinator(action: action) }
        final class Coordinator: NSObject {
            let action: () -> Void
            init(action: @escaping () -> Void) {
                self.action = action
            }
            @objc func tap() { action() }
        }
    }
#endif
}

struct LoginView: View {
    @EnvironmentObject var auth: AuthState
    @State private var coordinator: AppleSignInCoordinator? = nil
    
    @State private var userId = ""
    @State private var password = ""
    @State private var message = ""
    @State private var showRegister = false
    @State private var showForgot = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                    .padding(.top, 24)
                
                Text("サインイン").font(.title3.bold())
                
                VStack(spacing: 12) {
                    TextField("ID", text: $userId)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .textContentType(.username)
                        .submitLabel(.next)
                        .padding(12)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    
                    SecureField("パスワード", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .padding(12)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                .padding(.horizontal)
                
                if !message.isEmpty {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
                
                // ログイン
                Button {
                    if AccountsStore.verify(id: userId, password: password) {
                        // ローカルIDログイン成功 → 現在ユーザーを更新
                        CurrentUserStore.setCurrent(userId)
                        auth.userId = userId
                        message = ""
                    } else {
                        message = "IDまたはパスワードが違います"
                    }
                } label: {
                    Text("ログイン").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                
                // 新規登録（シート表示）
                Button {
                    showRegister = true
                } label: {
                    Text("新規登録").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)
                .sheet(isPresented: $showRegister) {
                    RegistrationView(isPresented: $showRegister)
                        .environmentObject(auth)
                }
                
                // パスワードをお忘れですか？
                Button {
                    showForgot = true
                } label: {
                    Text("パスワードをお忘れですか？")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .sheet(isPresented: $showForgot) {
                    ForgotPasswordView(isPresented: $showForgot)
                }
                
                // 生体認証でログイン
                if BiometricAuth.canEvaluate().ok {
                    Button {
                        BiometricAuth.authenticate(reason: "ログインを行います") { result in
                            switch result {
                            case .success:
                                if let lastId = CurrentUserStore.load(), AccountsStore.exists(id: lastId) {
                                    auth.userId = lastId
                                    message = ""
                                } else if let appleId = KeychainAuth.loadAppleUserId() {
                                    // Appleでサインインの既存キーがあればそれでログイン
                                    CurrentUserStore.setCurrent(appleId)
                                    auth.userId = appleId
                                    message = ""
                                } else {
                                    message = "まずID/PASSまたはAppleで一度ログインしてください"
                                }
                            case .failure(let e):
                                message = e.localizedDescription
                            }
                        }
                    } label: {
                        Text("Face ID / Touch ID でログイン").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal)
                }
                
                // 区切り
                HStack { Rectangle().frame(height: 1).opacity(0.1); Text("または").foregroundStyle(.secondary); Rectangle().frame(height: 1).opacity(0.1) }
                    .padding(.horizontal)
                
                // Appleでサインイン
                AppleIDButtonRepresentable {
                    coordinator = AppleSignInCoordinator { result in
                        switch result {
                        case .success(let id):
                            // AppleIDログイン成功 → current user 更新
                            CurrentUserStore.setCurrent(id)
                            if KeychainAuth.saveAppleUserId(id) { auth.userId = id } else { message = "Keychain保存に失敗" }
                        case .failure(let err):
                            message = "Appleサインインに失敗: \(err.localizedDescription)"
                        }
                        DispatchQueue.main.async { coordinator = nil }
                    }
                    coordinator?.signIn()
                }
                .padding(.bottom, 24)
                .padding(.horizontal)
            }
        }
        .navigationTitle("ログイン")
    }
}

// パスワード再設定画面をトップレベルに移動
struct ForgotPasswordView: View {
    @Binding var isPresented: Bool
    @State private var ownerMenuPass: String = ""
    @State private var loginId: String = ""
    @State private var newPass: String = ""
    @State private var message: String = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section("本人確認（オーナー）") {
                    SecureField("オーナーメニューのパスワード", text: $ownerMenuPass)
#if targetEnvironment(simulator)
                        .textContentType(.password)
#else
                        .textContentType(.newPassword)
#endif
                }
                Section("対象アカウント") {
                    TextField("ログインID", text: $loginId)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .textContentType(.username)
                    SecureField("新しいパスワード", text: $newPass)
#if targetEnvironment(simulator)
                        .textContentType(.password)
#else
                        .textContentType(.newPassword)
#endif
                }
                if !message.isEmpty { Section { Text(message).foregroundStyle(.red) } }
                Section {
                    Button("パスワードを再設定") { reset() }
                        .buttonStyle(.borderedProminent)
                        .disabled(loginId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newPass.isEmpty)
                }
            }
            .navigationTitle("パスワード再設定")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { isPresented = false } } }
        }
    }
    
    private func reset() {
        guard let saved = Keychain.load() else { message = "オーナーパスワードが未設定です"; return }
        guard sha256(ownerMenuPass) == saved else { message = "オーナーパスワードが違います"; return }
        let trimmedId = loginId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AccountsStore.exists(id: trimmedId) else { message = "そのIDは登録されていません"; return }
        guard newPass.count >= 4 else { message = "新パスワードは4文字以上にしてください"; return }
        switch AccountsStore.setPassword(id: trimmedId, password: newPass) {
        case .success:
            message = "再設定しました"
            // 自動で閉じるなら少し遅延して閉じる
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { isPresented = false }
        case .failure(let err):
            message = err.localizedDescription
        }
    }
}

struct RegistrationView: View {
    @EnvironmentObject var auth: AuthState
    @Binding var isPresented: Bool
    
    @State private var ownerName: String = ""
    @State private var companyName: String = ""
    @State private var birthDate: Date = Calendar.current.date(from: DateComponents(year: 1990, month: 1, day: 1)) ?? Date()
    @State private var ownerMenuPass: String = ""
    @State private var loginId: String = ""
    @State private var loginPass: String = ""
    
    @State private var message: String = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section("オーナー情報") {
                    TextField("オーナー氏名", text: $ownerName)
                    TextField("会社名", text: $companyName)
                    DatePicker("生年月日", selection: $birthDate, displayedComponents: .date)
                }
                Section("認証設定") {
                    SecureField("オーナーメニューのパスワード", text: $ownerMenuPass)
#if targetEnvironment(simulator)
                        .textContentType(.password)
#else
                        .textContentType(.newPassword)
#endif
                    TextField("ログインID", text: $loginId)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .textContentType(.username)
                    SecureField("ログイン用パスワード", text: $loginPass)
#if targetEnvironment(simulator)
                        .textContentType(.password)
#else
                        .textContentType(.newPassword)
#endif
                }
                if !message.isEmpty {
                    Section { Text(message).foregroundStyle(.red) }
                }
                Section {
                    Button("登録してログイン") { register() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("新規登録")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { isPresented = false }
                }
            }
        }
    }
    
    private func register() {
        // 入力バリデーション
        let trimmedName = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCompany = companyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { message = "オーナー氏名を入力してください"; return }
        guard !trimmedCompany.isEmpty else { message = "会社名を入力してください"; return }
        guard isStrongPassword(ownerMenuPass) else { message = "オーナーメニューのパスワードは英字・数字・記号を含む8文字以上で設定してください"; return }
        guard !loginId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { message = "ログインIDを入力してください"; return }
        guard loginPass.count >= 4 else { message = "ログインパスワードは4文字以上にしてください"; return }
        
        // 1) ログインID/PASS登録
        switch AccountsStore.register(id: loginId, password: loginPass) {
        case .failure(let err):
            message = err.localizedDescription
            return
        case .success:
            break
        }
        // 2) オーナーメニュー用パスワードをKeychainへ
        guard Keychain.save(hash: sha256(ownerMenuPass)) else {
            message = "オーナーパスワードの保存に失敗しました"
            return
        }
        // 3) プロファイル保存
        let profile = OwnerProfile(ownerName: trimmedName, companyName: trimmedCompany, birthDateISO8601: isoDateString(birthDate))
        OwnerProfileStore.save(profile)
        
        // 4) 現在ユーザーを設定 → 自動ログイン → シート閉じ
        CurrentUserStore.setCurrent(loginId)
        auth.userId = loginId
        isPresented = false
    }
}

struct RootView: View {
    @StateObject var auth = AuthState()
    @StateObject var manager = AttendanceManager() // ContentView側で独自生成してもOK。必要ならここを子に渡す
    
    var body: some View {
        Group {
            if let _ = auth.userId {
                ContentView()
                    .environmentObject(manager)
                    .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("サインアウト") { auth.signOut() } } }
            } else {
                NavigationStack { LoginView().environmentObject(auth) }
            }
        }
        .onAppear {
            // 起動時・復帰時に現在のユーザーIDで名前空間を合わせる
            manager.switchUser(CurrentUserStore.load())
            manager.checkAndAutoBackup()
        }
        .onChange(of: auth.userId) { oldId, newId in
            // ログイン状態が変われば保存領域も切替
            manager.switchUser(newId ?? CurrentUserStore.load())
        }
    }
}

// MARK: - Root Menu
struct ContentView: View {
    @EnvironmentObject var manager: AttendanceManager
    @State private var showOwnerGate = false
    var body: some View {
        NavigationStack {
            List {
                Section("機能メニュー") {
                    NavigationLink { AttendanceView().environmentObject(manager) } label: { Label("勤怠", systemImage: "calendar.badge.clock") }
                    Button { showOwnerGate = true } label: { Label("オーナーメニュー", systemImage: "lock.shield") }
                }
            }
            .navigationTitle("メニュー")
            .sheet(isPresented: $showOwnerGate) {
                OwnerGateView { showOwnerGate = false } content: { OwnerMenuView() }
                    .environmentObject(manager)
            }
        }
    }
}

// MARK: - Attendance View
struct AttendanceView: View {
    @EnvironmentObject var manager: AttendanceManager
    private let timeDF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    var body: some View {
        List {
            ForEach(manager.staffs) { staff in
                let r = manager.record(for: staff)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(staff.name).font(.headline)
                        Spacer()
                        if let secs = r.totalSecondsWorked { Text(String(format: "%.2f h", secs/3600)).foregroundStyle(.secondary) }
                    }
                    HStack(spacing: 8) {
                        Button("出勤") { manager.clockIn(staff) }.buttonStyle(.borderedProminent)
                        Button("退勤") { manager.clockOut(staff) }.buttonStyle(.bordered)
                        Button("休憩開始") { manager.breakStart(staff) }.buttonStyle(.bordered).tint(.orange).disabled(r.isOnBreak)
                        Button("休憩戻り") { manager.breakEnd(staff) }.buttonStyle(.bordered).tint(.green).disabled(!r.isOnBreak)
                        Button("賄い") { manager.addMeal(staff) }.buttonStyle(.bordered).tint(.purple)
                    }
                    .lineLimit(1).minimumScaleFactor(0.85)
                    HStack(spacing: 12) {
                        Label(r.clockIn.map{ timeDF.string(from: $0) } ?? "--", systemImage: "play.fill")
                        Label(r.clockOut.map{ timeDF.string(from: $0) } ?? "--", systemImage: "stop.fill")
                        Label("休憩 \(r.breakMinutes)分", systemImage: "cup.and.saucer.fill")
                        Label("賄い \(r.mealCount)回", systemImage: "takeoutbag.and.cup.and.straw.fill")
                        if r.isOnBreak { Text("(休憩中)").foregroundStyle(.orange) }
                    }.font(.footnote).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            }
        }.navigationTitle("勤怠")
    }
}

// MARK: - Owner Gate
struct OwnerGateView<Content: View>: View {
    @State private var input = ""
    @State private var error = ""
    @State private var isSetMode: Bool = (Keychain.load() == nil)
    @State private var authed = false
    @State private var triedBio = false
    let onSuccess: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        NavigationStack {
            if authed {
                content()
                    .toolbar {
#if os(iOS)
                        ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { onSuccess() } }
#else
                        ToolbarItem(placement: .automatic) { Button("閉じる") { onSuccess() } }
#endif
                    }
            } else {
                Form {
                    Section(isSetMode ? "オーナーパスワードを設定" : "パスワード入力") {
                        SecureField("パスワード", text: $input)
                        if !error.isEmpty { Text(error).foregroundStyle(.red) }
                    }
                    Section { Button(isSetMode ? "設定する" : "入る") { action() }.buttonStyle(.borderedProminent) }
                    Section {
                        if BiometricAuth.canEvaluate().ok {
                            Button {
                                BiometricAuth.authenticate(reason: isSetMode ? "オーナーパスワード設定のため認証" : "オーナー確認") { result in
                                    switch result {
                                    case .success:
                                        // 生体認証は本人端末の所有確認。パスワード未設定時はセット画面に誘導
                                        if isSetMode {
                                            // そのまま設定入力を促す
                                            error = "生体認証OK。パスワードを設定してください"
                                        } else {
                                            error = ""; input = ""; authed = true
                                        }
                                    case .failure(let e):
                                        error = e.localizedDescription
                                    }
                                }
                            } label: {
                                Label("Face ID / Touch ID で確認", systemImage: "faceid")
                            }
                        }
                    }
                }
                .onAppear {
                    guard !triedBio else { return }
                    triedBio = true
                    if BiometricAuth.canEvaluate().ok {
                        BiometricAuth.authenticate(reason: isSetMode ? "オーナーパスワード設定のため認証" : "オーナー確認") { result in
                            switch result {
                            case .success:
                                if isSetMode {
                                    // そのまま設定入力を促す
                                    error = "生体認証OK。パスワードを設定してください"
                                } else {
                                    error = ""; input = ""; authed = true
                                }
                            case .failure(let e):
                                // 失敗時はエラー表示に留め、ユーザーはパスワードで続行可能
                                error = e.localizedDescription
                            }
                        }
                    }
                }
                .navigationTitle("オーナー")
            }
        }
    }
    private func action() {
        if isSetMode {
            guard isStrongPassword(input) else { error = "英字・数字・記号を含む8文字以上で設定してください"; return }
            let ok = Keychain.save(hash: sha256(input))
            if ok { isSetMode = false; input = ""; error = "" } else { error = "保存に失敗しました" }
        } else {
            guard let saved = Keychain.load() else { error = "未設定です。設定してください"; isSetMode = true; return }
            if sha256(input) == saved { error = ""; input = ""; authed = true } else { error = "パスワードが違います" }
        }
    }
}

// MARK: - Owner Menu
struct OwnerMenuView: View {
    @EnvironmentObject var manager: AttendanceManager
    private struct BackupMessage: Identifiable {
        let id = UUID()
        let text: String
    }
    var body: some View {
        List {
            NavigationLink { StaffManageView() } label: { Label("スタッフの人数・名前の変更", systemImage: "person.3") }
            NavigationLink { AttendanceEditNewView() } label: { Label("勤怠記録の修正", systemImage: "pencil") }
            NavigationLink { PayrollView() } label: { Label("給与計算", systemImage: "yensign.circle") }
            Section("データ管理") {
                Button("バックアップを保存（日付付き）") {
                    manager.backupToFile()
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                
                Button("最新のバックアップから復元") {
                    manager.restoreLatestBackup()
                }
                .buttonStyle(.bordered)
            }
        }
        .navigationTitle("オーナーメニュー")
        .alert(item: Binding(
            get: { manager.lastBackupMessage.map { BackupMessage(text: $0) } },
            set: { _ in manager.lastBackupMessage = nil }
        )) { msg in
            Alert(title: Text("バックアップ"), message: Text(msg.text), dismissButton: .default(Text("OK")))
        }
    }
}

// MARK: - Attendance Edit New View
struct AttendanceEditNewView: View {
    @EnvironmentObject var manager: AttendanceManager
    @State private var targetDate = Date()
    @State private var editableRecords: [EditableRecord] = []
    @State private var showSaved = false
    
    struct EditableRecord: Identifiable, Hashable {
        var id = UUID()
        var staffId: UUID? = nil
        var clockIn: Date? = nil
        var clockOut: Date? = nil
        var breakMinutes: Int = 0
        var mealCount: Int = 0
    }
    
    var body: some View {
        Form {
            Section("日付") {
                DatePicker("日付", selection: $targetDate, displayedComponents: .date)
                    .onChange(of: targetDate) { _, _ in loadForDate() }
            }
            Section(header: Text("スタッフごとの勤怠")) {
                ForEach($editableRecords) { $rec in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Menu {
                                ForEach(manager.staffs, id: \.id) { s in
                                    Button(s.name) { rec.staffId = s.id }
                                }
                                Button("未選択") { rec.staffId = nil }
                            } label: {
                                Text(rec.staffId.flatMap { staffName(for: $0) } ?? "スタッフ選択")
                                    .foregroundStyle(rec.staffId == nil ? .secondary : .primary)
                            }
                            Spacer()
                        }
                        HStack {
                            DatePicker("出勤", selection: Binding<Date>.fromOptional($rec.clockIn, default: defaultTime(hour: 9)), displayedComponents: .hourAndMinute)
                                .labelsHidden()
                            Button(action: { rec.clockIn = nil }) {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                            }.opacity(rec.clockIn != nil ? 1 : 0.2)
                        }
                        HStack {
                            DatePicker("退勤", selection: Binding<Date>.fromOptional($rec.clockOut, default: defaultTime(hour: 18)), displayedComponents: .hourAndMinute)
                                .labelsHidden()
                            Button(action: { rec.clockOut = nil }) {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                            }.opacity(rec.clockOut != nil ? 1 : 0.2)
                        }
                        Stepper(value: $rec.breakMinutes, in: 0...600, step: 5) {
                            Text("休憩 \(rec.breakMinutes) 分")
                        }
                        Stepper(value: $rec.mealCount, in: 0...5, step: 1) {
                            Text("賄い \(rec.mealCount) 回")
                        }
                    }
                    .padding(.vertical, 6)
                }
                Button(action: addRow) {
                    Label("行を追加", systemImage: "plus")
                }
            }
            Section {
                Button("保存") { saveAll() }
                    .buttonStyle(.borderedProminent)
            }
            if showSaved {
                Section { Text("保存しました").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("勤怠記録の修正（新）")
        .onAppear { loadForDate() }
    }
    
    private func staffName(for id: UUID) -> String? {
        manager.staffs.first(where: { $0.id == id })?.name
    }
    private func defaultTime(hour: Int) -> Date {
        let cal = Calendar.current
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: targetDate) ?? targetDate
    }
    private func loadForDate() {
        let cal = Calendar.current
        editableRecords = manager.records.values
            .filter { cal.isDate($0.date, inSameDayAs: targetDate) }
            .map {
                EditableRecord(
                    staffId: $0.staffId,
                    clockIn: $0.clockIn,
                    clockOut: $0.clockOut,
                    breakMinutes: $0.breakMinutes,
                    mealCount: $0.mealCount
                )
            }
    }
    private func addRow() {
        editableRecords.append(EditableRecord())
    }
    private func saveAll() {
        for rec in editableRecords {
            guard let staffId = rec.staffId,
                  let staff = manager.staffs.first(where: { $0.id == staffId }) else { continue }
            manager.updateRecord(
                staff: staff,
                on: Calendar.current.startOfDay(for: targetDate),
                clockIn: rec.clockIn,
                clockOut: rec.clockOut,
                breakMinutes: rec.breakMinutes,
                mealCount: rec.mealCount
            )
        }
        showSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showSaved = false
        }
    }
}

// MARK: - Optional Binding for DatePicker
extension Binding where Value == Date {
    /// Map an optional Date binding to a non-optional Date binding for DatePicker
    static func fromOptional(_ optional: Binding<Date?>, default defaultDate: Date) -> Binding<Date> {
        Binding<Date>(
            get: { optional.wrappedValue ?? defaultDate },
            set: { newValue in optional.wrappedValue = newValue }
        )
    }
}

// MARK: - Staff Manage
struct StaffManageView: View {
    @EnvironmentObject var manager: AttendanceManager
    @State private var newName = ""
    var body: some View {
        List {
            Section("スタッフ一覧") {
                ForEach(manager.staffs) { s in
                    HStack {
                        TextField("名前", text: Binding(get: { s.name }, set: { manager.rename(s, to: $0) }))
                            .textInputAutocapitalization(.never).disableAutocorrection(true)
                    }
                }.onDelete { idx in idx.compactMap { manager.staffs[$0] }.forEach(manager.remove) }
            }
            Section("追加") {
                HStack {
                    TextField("名前を入力", text: $newName).textInputAutocapitalization(.never).disableAutocorrection(true)
                    Button("追加") {
                        let t = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { return }
                        manager.addStaff(name: t); newName = ""
                    }.buttonStyle(.borderedProminent)
                }
            }
        }.toolbar { EditButton() }.navigationTitle("スタッフ管理")
    }
}


// MARK: - Number Formatter
fileprivate let yenFormatter: NumberFormatter = {
    let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = ","; f.maximumFractionDigits = 0; return f
}()

// MARK: - Payroll Row
private struct PayrollRowView: View {
    let name: String
    @Binding var hourlyText: String
    @Binding var mealText: String
    let meals: Int
    let totalPayText: String
    var body: some View {
        HStack(spacing: 8) {
            Text(name).frame(minWidth: 140, alignment: .leading).lineLimit(1).minimumScaleFactor(0.85)
            HStack(spacing: 4) {
                TextField("時給", text: $hourlyText)
                    .multilineTextAlignment(.trailing).frame(width: 70)
                Text("円").font(.caption)
            }.frame(width: 100, alignment: .trailing)
            HStack(spacing: 4) {
                TextField("賄い", text: $mealText)
                    .multilineTextAlignment(.trailing).frame(width: 70)
                Text("円").font(.caption)
            }.frame(width: 110, alignment: .trailing)
            Text("\(meals) 回").frame(width: 90, alignment: .trailing)
            Text(totalPayText).frame(width: 120, alignment: .trailing)
        }
    }
}

// MARK: - Payroll
struct PayrollView: View {
    @EnvironmentObject var manager: AttendanceManager
    @State private var targetMonth = Calendar.current.startOfDay(for: Date())
    @AppStorage("payroll_rounding_mode") private var roundingRaw: String = RoundingMode.minute1.rawValue
    @State private var isExporting = false
    @State private var csvDoc: CSVDocument? = nil
    private var roundingMode: RoundingMode { RoundingMode(rawValue: roundingRaw) ?? .minute1 }
    var body: some View {
        Form {
            Section("対象月") {
                DatePicker("月", selection: $targetMonth, displayedComponents: .date)
                Picker("端数処理", selection: $roundingRaw) {
                    ForEach(RoundingMode.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }.pickerStyle(.segmented)
            }
            Section(footer: Text("給与 = （月間総労働時間 × 時給） − （賄い回数 × 賄い単価）。金額は3桁区切りで表示します。")) {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("スタッフ名").frame(minWidth: 140, alignment: .leading).font(.caption.bold()).lineLimit(1)
                            Text("時給").frame(width: 100, alignment: .trailing).font(.caption.bold())
                            Text("賄い(単価)").frame(width: 110, alignment: .trailing).font(.caption.bold())
                            Text("賄い日数").frame(width: 90, alignment: .trailing).font(.caption.bold())
                            Text("給与").frame(width: 120, alignment: .trailing).font(.caption.bold())
                        }
                        Divider()
                        ForEach(manager.staffs.indices, id: \.self) { idx in
                            let s = manager.staffs[idx]
                            let totalH = manager.monthlyTotalHours(for: s, month: targetMonth, rounding: roundingMode)
                            let wage = s.hourlyWageYen ?? 0
                            let mealUnit = s.mealAllowanceYen ?? 0
                            let meals = manager.monthlyMealCount(for: s, month: targetMonth)
                            let basePay = Int((totalH * Double(wage)).rounded())
                            let mealPay = mealUnit * meals
                            let totalPayText = formattedYen(basePay - mealPay)
                            let wageBinding = Binding<String>(
                                get: { manager.staffs[idx].hourlyWageYen.map(String.init) ?? "" },
                                set: { input in
                                    let val = Int(input.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces))
                                    manager.setHourlyWage(val, for: manager.staffs[idx])
                                }
                            )
                            let mealBinding = Binding<String>(
                                get: { manager.staffs[idx].mealAllowanceYen.map(String.init) ?? "" },
                                set: { input in
                                    let val = Int(input.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces))
                                    manager.setMealAllowance(val, for: manager.staffs[idx])
                                }
                            )
                            PayrollRowView(name: s.name, hourlyText: wageBinding, mealText: mealBinding, meals: meals, totalPayText: totalPayText)
                        }
                    }.frame(minWidth: 560, alignment: .leading)
                }.padding(.vertical, 4)
            }
            Section {
                Button {
                    if let data = exportCSVData() { csvDoc = CSVDocument(data: data); isExporting = true }
                } label: { Label("Excel(互換CSV)で出力", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .fileExporter(isPresented: $isExporting, document: csvDoc, contentType: .commaSeparatedText, defaultFilename: "payroll_\(monthString)") { _ in }
        .navigationTitle("給与計算")
    }
    private var monthString: String { let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f.string(from: targetMonth) }
    private func formattedYen(_ value: Int) -> String { yenFormatter.string(from: NSNumber(value: value)).map { "\($0) 円" } ?? "\(value) 円" }
    private func exportCSVData() -> Data? {
        // ヘッダ: 「◯月, 打刻, 日付, 1..末日, 時給, 賄い単価, 勤務日数, 労働時間（合計）, 賄い回数, 支給額」
        let cal = Calendar.current
        // 月初と月末（翌月月初の前日）
        guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: targetMonth)),
              let nextMonth = cal.date(byAdding: DateComponents(month: 1), to: monthStart),
              let lastDayInMonth = cal.date(byAdding: .day, value: -1, to: nextMonth) else {
            return nil
        }
        let daysCount = cal.component(.day, from: lastDayInMonth)
        let monthLabel: String = {
            let f = DateFormatter(); f.dateFormat = "yyyy年MM月"; return f.string(from: monthStart)
        }()
        
        var rows: [[String]] = []
        var header: [String] = [monthLabel, "打刻", "日付"]
        header += (1...daysCount).map { String($0) }
        header += ["時給", "賄い単価", "勤務日数", "労働時間（合計）", "賄い回数", "支給額"]
        rows.append(header)
        
        // フォーマッタ
        let timeF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
        let hourFmt: (Double) -> String = { String(format: "%.2f", $0) }
        
        // 各スタッフ 4行（出勤/退勤/賄い/労働時間）で出力
        for s in manager.staffs {
            // 対象月の1日〜末日で日付キーを用意
            var byDay: [Int: AttendanceRecord] = [:]
            for day in 1...daysCount {
                if let d = cal.date(bySetting: .day, value: day, of: monthStart) {
                    let rec = manager.record(for: s, on: d)
                    byDay[day] = rec
                }
            }
            
            // 集計
            let totalHours: Double = manager.monthlyTotalHours(for: s, month: monthStart, rounding: RoundingMode(rawValue: roundingRaw) ?? .minute1)
            let totalMeals: Int = manager.monthlyMealCount(for: s, month: monthStart)
            let workDays: Int = (1...daysCount).reduce(0) { acc, day in
                if let r = byDay[day], r.totalSecondsWorked ?? 0 > 0 { return acc + 1 } else { return acc }
            }
            let wage = s.hourlyWageYen ?? 0
            let mealUnit = s.mealAllowanceYen ?? 0
            let basePay = Int((totalHours * Double(wage)).rounded())
            let mealPay = mealUnit * totalMeals
            let totalPay = basePay - mealPay
            
            // 出勤行
            var rowIn: [String] = [monthLabel, "出勤", "日付"]
            for day in 1...daysCount {
                if let r = byDay[day], let t = r.clockIn { rowIn.append(timeF.string(from: t)) } else { rowIn.append("") }
            }
            rowIn += ["", "", "", "", "", ""] // サマリ列は出勤行では空
            // スタッフ名は出勤行の先頭に表示（Excelサンプル準拠で1列目に名前、2列目に打刻種別）
            rowIn[0] = s.name
            rows.append(rowIn)
            
            // 退勤行
            var rowOut: [String] = ["", "退勤", "日付"]
            for day in 1...daysCount {
                if let r = byDay[day], let t = r.clockOut { rowOut.append(timeF.string(from: t)) } else { rowOut.append("") }
            }
            rowOut += ["", "", "", "", "", ""]
            rows.append(rowOut)
            
            // 賄い行（1 or 空）
            var rowMeal: [String] = ["", "賄い", "日付"]
            for day in 1...daysCount {
                if let r = byDay[day], r.mealCount > 0 { rowMeal.append(String(r.mealCount)) } else { rowMeal.append("") }
            }
            rowMeal += ["", "", "", "", "", ""]
            rows.append(rowMeal)
            
            // 労働時間行（小数時間）＋サマリ値
            var rowHours: [String] = ["", "労働時間", "日付"]
            for day in 1...daysCount {
                if let r = byDay[day], let secs = r.totalSecondsWorked {
                    // 端数処理に合わせて日ごとの時間を丸める
                    let mode = RoundingMode(rawValue: roundingRaw) ?? .minute1
                    let mins: Double
                    switch mode {
                    case .minute1:
                        mins = (secs / 60).rounded()
                    case .quarter15:
                        let m = secs / 60
                        let remainder = m.truncatingRemainder(dividingBy: 15)
                        if remainder >= 7.5 {
                            mins = (m - remainder + 15) // 出勤に近い扱い（切り上げ）
                        } else {
                            mins = (m - remainder)      // 退勤に近い扱い（切り下げ）
                        }
                    }
                    rowHours.append(hourFmt(mins / 60))
                } else {
                    rowHours.append("")
                }
            }
            rowHours.append(String(wage))
            rowHours.append(String(mealUnit))
            rowHours.append(String(workDays))
            rowHours.append(hourFmt(totalHours))
            rowHours.append(String(totalMeals))
            rowHours.append(String(totalPay))
            rows.append(rowHours)
        }
        
        // CSV 生成（Excel互換のため BOM付きUTF-8）
        let csv = rows.map { cols in
            cols.map { col in
                if col.contains(",") || col.contains("\n") || col.contains("\"") {
                    let escaped = col.replacingOccurrences(of: "\"", with: "\"\"")
                    return "\"\(escaped)\""
                } else {
                    return col
                }
            }.joined(separator: ",")
        }.joined(separator: "\n")
        let bom = "\u{FEFF}"
        return (bom + csv).data(using: .utf8)
    }
}

// MARK: - CSV Document
struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        if let d = configuration.file.regularFileContents { self.data = d } else { self.data = Data() }
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

#Preview { RootView() }

