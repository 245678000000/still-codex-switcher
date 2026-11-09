import Foundation

/// Where the saved copy of a login last came from. Stored as text in accounts.json.
enum CredentialSource: String {
    case login      // official browser login started from 栖言
    case codex      // picked up from the auth.json Codex is using
    case imported   // from an export file or a plain auth.json
}

/// How a saved copy is allowed to replace the one already in the Keychain.
enum StorePolicy {
    case replace    // explicit fresh login: always wins
    case keepNewer  // automatic or bulk paths: never overwrite a clearly newer copy
}
enum StoreOutcome: Equatable {
    case added(UUID), updated(UUID), unchanged(UUID), keptNewer(UUID)
    var id: UUID {
        switch self {
        case .added(let id), .updated(let id), .unchanged(let id), .keptNewer(let id): return id
        }
    }
    var changed: Bool {
        switch self {
        case .added, .updated: return true
        case .unchanged, .keptNewer: return false
        }
    }
}

/// What 栖言 can honestly say about one saved login, from local token times plus the
/// last answer of the official service for this exact copy. Refresh tokens are never used
/// to check, so "expired" means only the short-lived access token has run out.
enum AuthHealth: Equatable {
    case checking
    case locked
    case unavailable
    case valid(expiresAt: Date?)
    case unverified(expiresAt: Date?)
    case expired(at: Date)
    case invalid(since: Date)

    enum Tone { case good, neutral, warning, danger }

    static func evaluate(stamp: CredentialStamp?, verdict: AuthVerdict?, now: Date = Date()) -> AuthHealth {
        guard let stamp else { return .unverified(expiresAt: nil) }
        let pastExpiry = stamp.expiresAt.map { $0 <= now } ?? false
        if let verdict, verdict.fingerprint == stamp.fingerprint {
            switch verdict.kind {
            case .rejected:
                // A 401 after the token's own expiry only means "expired"; before it, the login was withdrawn.
                if let exp = stamp.expiresAt, exp <= verdict.at { return .expired(at: exp) }
                return .invalid(since: verdict.at)
            case .accepted:
                if pastExpiry, let exp = stamp.expiresAt { return .expired(at: exp) }
                return .valid(expiresAt: stamp.expiresAt)
            }
        }
        if pastExpiry, let exp = stamp.expiresAt { return .expired(at: exp) }
        return .unverified(expiresAt: stamp.expiresAt)
    }

    var tone: Tone {
        switch self {
        case .checking: return .neutral
        case .locked, .unavailable: return .warning
        case .valid: return .good
        case .unverified: return .neutral
        case .expired: return .warning
        case .invalid: return .danger
        }
    }
    var isInvalid: Bool { if case .invalid = self { return true }; return false }
    var title: String {
        switch self {
        case .checking: return "验证中"
        case .locked: return "待解锁"
        case .unavailable: return "验证未完成"
        case .valid: return "认证有效"
        case .unverified: return "待验证"
        case .expired: return "令牌已过期"
        case .invalid: return "登录已失效"
        }
    }
    var symbol: String {
        switch self {
        case .checking: return "arrow.triangle.2.circlepath"
        case .locked: return "lock.fill"
        case .unavailable: return "wifi.exclamationmark"
        case .valid: return "checkmark.seal.fill"
        case .unverified: return "questionmark.circle"
        case .expired: return "clock.badge.exclamationmark"
        case .invalid: return "xmark.octagon.fill"
        }
    }
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
    /// One line for the badge tooltip and for accessibility.
    func detail(active: Bool) -> String {
        switch self {
        case .checking: return "正在优先验证这份登录，收到官方确认后显示认证有效。"
        case .locked: return "钥匙串需要授权，点击解锁登录后重试；这不代表账号失效。"
        case .unavailable: return "本次检查未完成，请检查连接或 CLI 后重试；这不代表账号失效。"
        case .valid(let exp):
            return "官方服务已接受这份登录" + (exp.map { " · 访问令牌 \(Self.stamp($0)) 到期" } ?? "") + (active ? " · Codex 正在使用，会自动续期" : "")
        case .unverified(let exp):
            return "这份登录还没有经过官方服务验证，刷新额度时会顺带检查" + (exp.map { " · 访问令牌 \(Self.stamp($0)) 到期" } ?? "")
        case .expired(let at):
            return active ? "访问令牌 \(Self.stamp(at)) 已过期 · Codex 正在使用，通常会自动续期"
                          : "访问令牌 \(Self.stamp(at)) 已过期 · 切换后 Codex 会尝试用刷新令牌续期；若 Codex 要求登录，请重新登录"
        case .invalid(let since):
            return "\(Self.stamp(since)) 官方服务拒绝了这份登录（未到期即被拒，常见于已退出、改密或同一份登录在别处续期过）· 需要重新登录"
        }
    }
}
