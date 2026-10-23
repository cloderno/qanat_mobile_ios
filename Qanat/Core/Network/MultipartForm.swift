import Foundation

/// Тело multipart/form-data — для загрузки фото, голосовых и видео.
struct MultipartForm {
    let boundary = "Boundary-\(UUID().uuidString)"
    private(set) var body = Data()

    mutating func addField(name: String, value: String) {
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.append("\(value)\r\n")
    }

    mutating func addFile(name: String, filename: String, mimeType: String, data: Data) {
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.append("\r\n")
    }

    /// [request] с телом формы и заголовком Content-Type.
    func request(_ request: URLRequest) -> URLRequest {
        var request = request
        var data = body
        data.append("--\(boundary)--\r\n")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return request
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
