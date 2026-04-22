import Vapor
import Fluent
import FluentPostgresDriver
import JWT
import Foundation

public func configure(_ app: Application) throws {
    app.logger.logLevel = .notice
    app.routes.defaultMaxBodySize = "1500mb"

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    ContentConfiguration.global.use(encoder: encoder, for: .json)
    ContentConfiguration.global.use(decoder: decoder, for: .json)
    
    // Настройка подключения к PostgreSQL
    let dbHost = Environment.get("DB_HOST") ?? "127.0.0.1"
    let dbUser = Environment.get("DB_USERNAME") ?? "vapor_username"
    let dbPassword = Environment.get("DB_PASSWORD") ?? "vapor_password"
    let dbName = Environment.get("DB_NAME") ?? "lector_database"

    app.databases.use(.postgres(
        hostname: dbHost,
        port: 5432,
        username: dbUser,
        password: dbPassword,
        database: dbName
    ), as: .psql)

    // JWT
    let jwtSecret = Environment.get("JWT_SECRET") ?? "fallback_secret_for_dev"
    app.jwt.signers.use(.hs256(key: jwtSecret))
    
    // Регистрация миграций базы данных
    app.migrations.add(CreateUser())
    app.migrations.add(CreateRefreshToken())
    app.migrations.add(CreatePasswordToken())
    app.migrations.add(CreateFolder())
    app.migrations.add(CreateLecture())
    app.migrations.add(AddSummaryHistoryToLecture())
    
    try app.autoMigrate().wait()

    // Инициализация нейросети
    let transcriber = TranscriptionActor()
    app.storage[TranscriptionActorKey.self] = transcriber
    
    // Инициализация очереди
    app.storage[TranscriptionQueueKey.self] = TranscriptionQueue()

    Task(priority: .high) {
        print("--- [STARTUP] Initializing TranscriptionActor ---")
        await transcriber.loadModel()
        print("--- [STARTUP] Model loading attempt finished ---")
    }
    
    try routes(app)
}
