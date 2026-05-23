import Foundation

final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let progressHandler: @MainActor (Double) -> Void
    private let completion: @MainActor (Result<URL, Error>) -> Void
    private var downloadedURL: URL?
    private var responseError: Error?

    init(
        progressHandler: @escaping @MainActor (Double) -> Void,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
        self.progressHandler = progressHandler
        self.completion = completion
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in progressHandler(progress) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            responseError = URLError(.badServerResponse)
            return
        }

        let stableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("simple-video-model-\(UUID().uuidString).bin")
        do {
            try FileManager.default.moveItem(at: location, to: stableURL)
            downloadedURL = stableURL
        } catch {
            responseError = error
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        session.finishTasksAndInvalidate()
        Task { @MainActor in
            if let error {
                completion(.failure(error))
            } else if let responseError {
                completion(.failure(responseError))
            } else if let downloadedURL {
                completion(.success(downloadedURL))
            } else {
                completion(.failure(URLError(.badServerResponse)))
            }
        }
    }
}
