import AVFoundation
import Foundation

final class Camera {
    enum PermissionStatus {
        case granted
        case denied
        case undetermined
    }

    enum Quality: String {
        case low, medium, high

        var preset: AVCaptureSession.Preset {
            switch self {
            case .low:    return .medium
            case .medium: return .high
            case .high:   return .hd1920x1080
            }
        }

        var compressionQuality: Float {
            switch self {
            case .low:    return 0.5
            case .medium: return 0.7
            case .high:   return 0.9
            }
        }
    }

    static let shared = Camera()

    private var session: AVCaptureSession?
    private var photoOutput: AVCapturePhotoOutput?
    private var videoOutput: AVCaptureMovieFileOutput?
    private var pendingCompletions: [UUID: (Result<URL, Error>) -> Void] = [:]

    private init() {}

    // MARK: - Permission

    func checkPermission() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:          return .granted
        case .denied, .restricted:  return .denied
        case .notDetermined:        return .undetermined
        @unknown default:           return .undetermined
        }
    }

    func requestPermission(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    // MARK: - Session Management

    func startSession() throws {
        guard session == nil else { return }
        let sess = AVCaptureSession()
        sess.sessionPreset = .high

        guard let device = AVCaptureDevice.default(for: .video) else {
            throw PeekError.cameraNotAvailable
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard sess.canAddInput(input) else {
            throw PeekError.cameraNotAvailable
        }
        sess.addInput(input)

        let photo = AVCapturePhotoOutput()
        guard sess.canAddOutput(photo) else {
            throw PeekError.cameraNotAvailable
        }
        sess.addOutput(photo)
        photoOutput = photo

        let video = AVCaptureMovieFileOutput()
        guard sess.canAddOutput(video) else {
            throw PeekError.cameraNotAvailable
        }
        sess.addOutput(video)
        videoOutput = video

        session = sess

        DispatchQueue.global(qos: .userInitiated).async {
            sess.startRunning()
        }
    }

    func stopSession() {
        session?.stopRunning()
        session = nil
        photoOutput = nil
        videoOutput = nil
    }

    // MARK: - Snapshot

    func takeSnapshot(quality: Quality = .medium, completion: @escaping (Result<URL, Error>) -> Void) {
        do {
            try ensureSession()
        } catch {
            completion(.failure(error))
            return
        }

        guard let photo = photoOutput else {
            completion(.failure(PeekError.cameraNotAvailable))
            return
        }

        let settings = AVCapturePhotoSettings()

        let outputURL = snapshotURL()
        let delegate = PhotoCaptureDelegate(outputURL: outputURL, completion: completion)
        photo.capturePhoto(with: settings, delegate: delegate)
    }

    // MARK: - Video Recording

    func startRecording(completion: @escaping (Result<(UUID, Date), Error>) -> Void) {
        do {
            try ensureSession()
        } catch {
            completion(.failure(error))
            return
        }

        guard let video = videoOutput else {
            completion(.failure(PeekError.cameraNotAvailable))
            return
        }

        let recordingID = UUID()
        let outputURL = videoURL(for: recordingID)

        let delegate = VideoRecordingDelegate(recordingID: recordingID) { [weak self] result in
            self?.pendingCompletions.removeValue(forKey: recordingID)
            completion(result)
        }
        pendingCompletions[recordingID] = { _ in }
        video.startRecording(to: outputURL, recordingDelegate: delegate)

        completion(.success((recordingID, Date())))
    }

    func stopRecording(recordingID: UUID, completion: @escaping (Result<(URL, TimeInterval), Error>) -> Void) {
        guard let video = videoOutput else {
            completion(.failure(PeekError.cameraNotAvailable))
            return
        }

        video.stopRecording()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.stopSession()
        }

        let outputURL = videoURL(for: recordingID)
        completion(.success((outputURL, 0)))
    }

    // MARK: - Frame Burst

    func captureFrames(count: Int, quality: Quality = .medium, completion: @escaping (Result<[Data], Error>) -> Void) {
        do {
            try ensureSession()
        } catch {
            completion(.failure(error))
            return
        }

        guard let photo = photoOutput else {
            completion(.failure(PeekError.cameraNotAvailable))
            return
        }

        var frames: [Data] = []
        var pendingCount = count
        let queue = DispatchQueue(label: "com.peek.frames")

        for _ in 0..<count {
            let settings = AVCapturePhotoSettings()

            let delegate = FrameCaptureDelegate { result in
                queue.async {
                    switch result {
                    case .success(let data):
                        frames.append(data)
                    case .failure:
                        break
                    }
                    pendingCount -= 1
                    if pendingCount == 0 {
                        DispatchQueue.main.async {
                            if frames.isEmpty {
                                completion(.failure(PeekError.encodingFailed))
                            } else {
                                completion(.success(frames))
                            }
                        }
                    }
                }
            }
            photo.capturePhoto(with: settings, delegate: delegate)
        }
    }

    // MARK: - Private Helpers

    private func ensureSession() throws {
        if session == nil {
            try startSession()
        }
        Thread.sleep(forTimeInterval: 0.3)
    }

    private func snapshotURL() -> URL {
        let dir = capturesDirectory()
        let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return dir.appendingPathComponent("snapshot_\(ts).jpg")
    }

    private func videoURL(for recordingID: UUID) -> URL {
        let dir = capturesDirectory()
        let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return dir.appendingPathComponent("video_\(ts)_\(recordingID.uuidString).mp4")
    }

    private func capturesDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Peek")
            .appendingPathComponent("Captures")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

private class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    let outputURL: URL
    let completion: (Result<URL, Error>) -> Void

    init(outputURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        self.outputURL = outputURL
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            completion(.failure(error))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            completion(.failure(PeekError.encodingFailed))
            return
        }
        do {
            try data.write(to: outputURL)
            completion(.success(outputURL))
        } catch {
            completion(.failure(error))
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

private class VideoRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    let recordingID: UUID
    let completion: (Result<(UUID, Date), Error>) -> Void

    init(recordingID: UUID, completion: @escaping (Result<(UUID, Date), Error>) -> Void) {
        self.recordingID = recordingID
        self.completion = completion
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        if let error = error {
            completion(.failure(error))
        } else {
            completion(.success((recordingID, Date())))
        }
    }
}

// MARK: - Frame Capture Delegate

private class FrameCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    let handler: (Result<Data, Error>) -> Void

    init(handler: @escaping (Result<Data, Error>) -> Void) {
        self.handler = handler
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            handler(.failure(error))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            handler(.failure(PeekError.encodingFailed))
            return
        }
        handler(.success(data))
    }
}