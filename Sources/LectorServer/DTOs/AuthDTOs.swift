import Vapor
import JWT

// Payload для Access Token (живет 15 минут)
struct UserPayload: JWTPayload, Authenticatable {
    var subject: SubjectClaim
    var expiration: ExpirationClaim

    enum CodingKeys: String, CodingKey {
        case subject = "sub"
        case expiration = "exp"
    }

    func verify(using signer: JWTSigner) throws {
        try expiration.verifyNotExpired()
    }
}

struct RegisterRequest: Content {
    let email: String
    let password: String
    let firstName: String
    let lastName: String
}

struct LoginRequest: Content {
    let email: String
    let password: String
}

struct RefreshTokenRequest: Content {
    let refreshToken: String
}

struct TokenResponse: Content {
    let accessToken: String
    let refreshToken: String
}

struct GoogleLoginRequest: Content {
    let idToken: String
}

struct GoogleTokenInfo: Content {
    let iss: String?
    let sub: String
    let aud: String?
    let email: String
    let email_verified: String?
    let name: String?
    let given_name: String?
    let family_name: String?
    let picture: String?
}

// MARK: - Восстановление пароля DTO

// восстановить пароль
struct ForgotPasswordRequest: Content {
    let email: String
}

// код из письма и новый пароль
struct ResetPasswordRequest: Content {
    let email: String
    let code: String
    let newPassword: String
}

// Структура для отправки JSON на серверы Resend.com
struct ResendEmailPayload: Content {
    let from: String
    let to: [String]
    let subject: String
    let html: String
}
