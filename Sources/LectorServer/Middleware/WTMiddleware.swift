import Vapor
import JWT

struct JWTMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        do {
            _ = try request.jwt.verify(as: UserPayload.self)
        } catch {
            throw Abort(.unauthorized, reason: "Невалидный или отсутствующий токен доступа")
        }
        
        return try await next.respond(to: request)
    }
}
