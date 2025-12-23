import Vapor

public func configure(_ app: Application) async throws {
    app.routes.defaultMaxBodySize = "50MB"
    try routes(app)
}
