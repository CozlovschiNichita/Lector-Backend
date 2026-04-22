import Vapor
import Fluent
import JWT

struct AuthController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let authGroup = routes.grouped("auth")
        authGroup.post("register", use: register)
        authGroup.post("login", use: login)
        authGroup.post("refresh", use: refresh)
        authGroup.post("google-login", use: googleLogin)
        authGroup.post("forgot-password", use: forgotPassword)
        authGroup.post("reset-password", use: resetPassword)
        
        // НОВЫЙ МАРШРУТ: Удаление аккаунта
        authGroup.delete("account", use: deleteAccount)
    }

    // MARK: - Регистрация
    @Sendable
    func register(req: Request) async throws -> TokenResponse {
        let registerData = try req.content.decode(RegisterRequest.self)

        try validatePassword(registerData.password)

        if try await User.query(on: req.db).filter(\.$email == registerData.email).first() != nil {
            throw Abort(.conflict, reason: "Пользователь с таким email уже существует")
        }

        let hashedPassword = try Bcrypt.hash(registerData.password)
        let user = User(
            email: registerData.email,
            firstName: registerData.firstName,
            lastName: registerData.lastName,
            passwordHash: hashedPassword
        )
        
        try await user.save(on: req.db)
        return try await createTokenResponse(for: user, on: req)
    }

    // MARK: - Обычный Логин
    @Sendable
    func login(req: Request) async throws -> TokenResponse {
        let loginData = try req.content.decode(LoginRequest.self)

        guard let user = try await User.query(on: req.db).filter(\.$email == loginData.email).first() else {
            throw Abort(.unauthorized, reason: "Неверный email или пароль")
        }

        let isPasswordValid = try Bcrypt.verify(loginData.password, created: user.passwordHash)
        guard isPasswordValid else {
            throw Abort(.unauthorized, reason: "Неверный email или пароль")
        }

        return try await createTokenResponse(for: user, on: req)
    }

    // MARK: - Обновление токена (Refresh)
    @Sendable
    func refresh(req: Request) async throws -> TokenResponse {
        let refreshRequest = try req.content.decode(RefreshTokenRequest.self)
        
        guard let dbToken = try await RefreshToken.query(on: req.db)
            .filter(\.$token == refreshRequest.refreshToken)
            .with(\.$user)
            .first() else {
            throw Abort(.unauthorized, reason: "Сессия истекла, войдите заново")
        }
        
        guard dbToken.expiresAt > Date() else {
            try await dbToken.delete(on: req.db)
            throw Abort(.unauthorized, reason: "Сессия истекла")
        }
        
        let user = dbToken.user
        try await dbToken.delete(on: req.db)
        
        return try await createTokenResponse(for: user, on: req)
    }

    // MARK: - Вход через Google
    @Sendable
    func googleLogin(req: Request) async throws -> TokenResponse {
        let googleData = try req.content.decode(GoogleLoginRequest.self)
        
        let googleURI = URI(string: "https://oauth2.googleapis.com/tokeninfo?id_token=\(googleData.idToken)")
        let googleResponse = try await req.client.get(googleURI)
        
        guard googleResponse.status == .ok else {
            throw Abort(.unauthorized, reason: "Невалидный токен Google")
        }
        
        let userInfo = try googleResponse.content.decode(GoogleTokenInfo.self)
        
        let myClientID = "909923047688-l3ph8ob2ib3mb52oj2afrkqet4bsfk2a.apps.googleusercontent.com"
        guard userInfo.aud == myClientID else {
            throw Abort(.unauthorized, reason: "Токен выдан для другого приложения")
        }
        
        let googleID = userInfo.sub
        let userEmail = userInfo.email
        let firstName = userInfo.given_name
        let lastName = userInfo.family_name

        let existingUser = try await User.query(on: req.db).group(.or) { group in
            group.filter(\.$googleID == googleID)
            group.filter(\.$email == userEmail)
        }.first()

        if let user = existingUser {
            if user.googleID == nil {
                user.googleID = googleID
                try await user.save(on: req.db)
            }
            return try await createTokenResponse(for: user, on: req)
        } else {
            let newUser = User(
                email: userEmail,
                firstName: firstName,
                lastName: lastName,
                passwordHash: UUID().uuidString,
                googleID: googleID
            )
            try await newUser.save(on: req.db)
            return try await createTokenResponse(for: newUser, on: req)
        }
    }

    // MARK: - Восстановление пароля (отправка кода)
    @Sendable
    func forgotPassword(req: Request) async throws -> HTTPStatus {
        let requestData = try req.content.decode(ForgotPasswordRequest.self)
        
        guard let user = try await User.query(on: req.db)
            .filter(\.$email == requestData.email)
            .first() else {
            return .ok
        }
        
        guard let userId = user.id else { throw Abort(.internalServerError) }
        try await PasswordToken.query(on: req.db).filter(\.$user.$id == userId).delete()
        
        let code = String(format: "%06d", Int.random(in: 0...999999))
        let token = PasswordToken(
            token: code,
            userID: userId,
            expiresAt: Date().addingTimeInterval(60 * 15)
        )
        try await token.save(on: req.db)
        
        guard let resendApiKey = Environment.get("RESEND_API_KEY") else {
            req.logger.error("RESEND_API_KEY не найден")
            throw Abort(.internalServerError)
        }
        
        let emailPayload = ResendEmailPayload(
            from: "Lector App <noreply@vtuza.us>",
            to: [user.email],
            subject: "Код восстановления пароля Lector",
            html: """
            <div style="font-family: sans-serif; padding: 20px;">
                <h2 style="color: #333;">Восстановление пароля</h2>
                <p>Ваш секретный код для сброса пароля в приложении <b>Lector</b>:</p>
                <div style="background: #f4f4f4; padding: 15px; font-size: 24px; font-weight: bold; text-align: center; border-radius: 8px;">
                    \(code)
                </div>
                <p style="color: #666; margin-top: 20px;">Код действителен 15 минут.</p>
            </div>
            """
        )
        
        let resendURI = URI(string: "https://api.resend.com/emails")
        _ = try await req.client.post(resendURI) { clientReq in
            clientReq.headers.bearerAuthorization = BearerAuthorization(token: resendApiKey)
            try clientReq.content.encode(emailPayload, as: .json)
        }
        
        return .ok
    }

    // MARK: - Сброс пароля (Reset)
    @Sendable
    func resetPassword(req: Request) async throws -> HTTPStatus {
        let requestData = try req.content.decode(ResetPasswordRequest.self)
        
        try validatePassword(requestData.newPassword)
        
        guard let user = try await User.query(on: req.db).filter(\.$email == requestData.email).first(),
              let userId = user.id else {
            throw Abort(.notFound, reason: "Пользователь не найден")
        }
        
        guard let dbToken = try await PasswordToken.query(on: req.db)
            .filter(\.$user.$id == userId)
            .filter(\.$token == requestData.code)
            .first() else {
            throw Abort(.unauthorized, reason: "Неверный или просроченный код")
        }
        
        guard dbToken.expiresAt > Date() else {
            try await dbToken.delete(on: req.db)
            throw Abort(.unauthorized, reason: "Срок действия кода истек")
        }
        
        user.passwordHash = try Bcrypt.hash(requestData.newPassword)
        try await user.save(on: req.db)
        try await dbToken.delete(on: req.db)
        
        return .ok
    }

    // MARK: - Удаление аккаунта
    @Sendable
    func deleteAccount(req: Request) async throws -> HTTPStatus {
        // Проверяем токен пользователя
        let payload = try req.jwt.verify(as: UserPayload.self)
        guard let userID = UUID(uuidString: payload.subject.value) else { throw Abort(.unauthorized) }
        
        // Находим юзера в базе
        guard let user = try await User.find(userID, on: req.db) else {
            throw Abort(.notFound)
        }
        
        // Удаляем пользователя (каскад удалит всё остальное)
        try await user.delete(on: req.db)
        
        return .noContent
    }

    // MARK: - Хелпер создания токенов
    private func createTokenResponse(for user: User, on req: Request) async throws -> TokenResponse {
        guard let userId = user.id else { throw Abort(.internalServerError) }
        
        let accessTokenPayload = UserPayload(
            subject: SubjectClaim(value: userId.uuidString),
            expiration: ExpirationClaim(value: Date().addingTimeInterval(60 * 15))
        )
        let accessToken = try req.jwt.sign(accessTokenPayload)
        
        let refreshTokenString = [UInt8].random(count: 32).base64
        let refreshToken = RefreshToken(
            token: refreshTokenString,
            userID: userId,
            expiresAt: Date().addingTimeInterval(60 * 60 * 24 * 30)
        )
        
        try await refreshToken.save(on: req.db)
        return TokenResponse(accessToken: accessToken, refreshToken: refreshTokenString)
    }

    // MARK: - валидация пароля
    private func validatePassword(_ password: String) throws {
        guard password.count >= 6 else {
            throw Abort(.badRequest, reason: "Пароль должен содержать минимум 6 символов")
        }
        
        let hasUppercase = password.rangeOfCharacter(from: .uppercaseLetters) != nil
        
        let hasDigit = password.rangeOfCharacter(from: .decimalDigits) != nil
        
        guard hasUppercase && hasDigit else {
            throw Abort(.badRequest, reason: "Пароль должен содержать заглавную букву и цифру")
        }
    }
}
