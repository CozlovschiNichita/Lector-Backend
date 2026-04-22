import Vapor
import Fluent

struct FolderController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let protected = routes.grouped(JWTMiddleware())
        let folders = protected.grouped("folders")
        
        folders.get(use: getAll)
        folders.post(use: create)
        folders.delete(":folderID", use: delete)
        folders.patch(":folderID", use: update)
    }

    @Sendable
    func getAll(req: Request) async throws -> [FolderDTO] {
        let payload = try req.jwt.verify(as: UserPayload.self)
        guard let userID = UUID(uuidString: payload.subject.value) else { throw Abort(.unauthorized) }

        let folders = try await Folder.query(on: req.db)
            .filter(\.$user.$id == userID)
            .sort(\.$createdAt, .descending)
            .all()

        return folders.map { FolderDTO(id: $0.id, name: $0.name, createdAt: $0.createdAt, colorHex: $0.colorHex) }
    }

    @Sendable
    func create(req: Request) async throws -> FolderDTO {
        let payload = try req.jwt.verify(as: UserPayload.self)
        guard let userID = UUID(uuidString: payload.subject.value) else { throw Abort(.unauthorized) }
        
        let folderData = try req.content.decode(FolderDTO.self)
        
        let folder = Folder(name: folderData.name, userID: userID, colorHex: folderData.colorHex)
        
        try await folder.save(on: req.db)
        return FolderDTO(id: folder.id, name: folder.name, createdAt: folder.createdAt, colorHex: folder.colorHex)
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let payload = try req.jwt.verify(as: UserPayload.self)
        guard let userID = UUID(uuidString: payload.subject.value),
              let folderID = req.parameters.get("folderID", as: UUID.self) else { throw Abort(.badRequest) }

        guard let folder = try await Folder.query(on: req.db)
            .filter(\.$id == folderID)
            .filter(\.$user.$id == userID)
            .first() else { throw Abort(.notFound) }

        // При удалении папки лекции не удалятся, у них просто folder_id станет NULL
        try await folder.delete(on: req.db)
        return .noContent
    }
    
    @Sendable
    func update(req: Request) async throws -> FolderDTO {
        let payload = try req.jwt.verify(as: UserPayload.self)
        guard let userID = UUID(uuidString: payload.subject.value),
              let folderID = req.parameters.get("folderID", as: UUID.self) else { throw Abort(.badRequest) }

        struct UpdateFolderRequest: Content {
            let name: String
            let colorHex: String?
        }
        
        let updateData = try req.content.decode(UpdateFolderRequest.self)
        
        guard let folder = try await Folder.query(on: req.db)
            .filter(\.$id == folderID)
            .filter(\.$user.$id == userID)
            .first() else { throw Abort(.notFound) }
            
        folder.name = updateData.name

        if let newColor = updateData.colorHex {
            folder.colorHex = newColor
        }
        
        try await folder.save(on: req.db)
        return FolderDTO(id: folder.id, name: folder.name, createdAt: folder.createdAt, colorHex: folder.colorHex)
    }
}
