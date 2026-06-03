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

    }

    static let shared = Camera()

    private var session: AVCaptureSession?
    private var captureDevice: AVCaptureDevice?
    private var selectedVideoDimensions: CMVideoDimensions?
    private var photoOutput: AVCapturePhotoOutput?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var photoDelegates: [UUID: PhotoCaptureDelegate] = [:]
    private var frameDelegates: [UUID: FrameCaptureDelegate] = [:]
    private var activeRecording: VideoFrameRecorder?
    private let sessionQueue = DispatchQueue(label: "com.peek.camera.session")

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

    // MARK: - Session Management

    func startSession() throws {
        let didStart = try startSessionIfNeeded()
        if didStart {
            waitForCameraWarmup()
        }
    }

    @discardableResult
    private func startSessionIfNeeded(quality: Quality = .medium) throws -> Bool {
        try sessionQueue.sync {
            guard session == nil else { return false }
            let sess = AVCaptureSession()

            guard let device = AVCaptureDevice.default(for: .video) else {
                throw PeekError.cameraNotAvailable
            }

            sess.beginConfiguration()
            if sess.canSetSessionPreset(quality.preset) {
                sess.sessionPreset = quality.preset
            } else if sess.canSetSessionPreset(.photo) {
                sess.sessionPreset = .photo
            }

            let input = try AVCaptureDeviceInput(device: device)
            guard sess.canAddInput(input) else {
                throw PeekError.cameraNotAvailable
            }
            sess.addInput(input)

            try configure(device: device)

            let photo = AVCapturePhotoOutput()
            guard sess.canAddOutput(photo) else {
                throw PeekError.cameraNotAvailable
            }
            sess.addOutput(photo)

            let video = AVCaptureVideoDataOutput()
            video.alwaysDiscardsLateVideoFrames = true
            var videoSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            if let dimensions = selectedVideoDimensions {
                videoSettings[kCVPixelBufferWidthKey as String] = Int(dimensions.width)
                videoSettings[kCVPixelBufferHeightKey as String] = Int(dimensions.height)
            }
            video.videoSettings = videoSettings
            guard sess.canAddOutput(video) else {
                throw PeekError.cameraNotAvailable
            }
            sess.addOutput(video)

            sess.commitConfiguration()

            sess.startRunning()
            captureDevice = device
            session = sess
            photoOutput = photo
            videoOutput = video

            return true
        }
    }

    func stopSession() {
        sessionQueue.sync {
            stopSessionOnQueue()
        }
    }

    func isActive() -> Bool {
        sessionQueue.sync {
            session?.isRunning ?? false
        }
    }

    // MARK: - Snapshot

    func takeSnapshot(quality: Quality = .medium, completion: @escaping (Result<URL, Error>) -> Void) {
        let shouldStopAfterCapture = session == nil

        do {
            try ensureSession(quality: quality)
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
        let captureID = UUID()
        let delegate = PhotoCaptureDelegate(outputURL: outputURL) { [weak self] result in
            self?.sessionQueue.async {
                self?.photoDelegates.removeValue(forKey: captureID)
                if shouldStopAfterCapture {
                    self?.stopSessionOnQueue()
                }
                DispatchQueue.main.async {
                    completion(result)
                }
            }
        }
        sessionQueue.sync {
            photoDelegates[captureID] = delegate
        }
        photo.capturePhoto(with: settings, delegate: delegate)
    }

    // MARK: - Video Recording

    func startRecording(completion: @escaping (Result<(UUID, Date), Error>) -> Void) {
        do {
            try ensureSession(quality: .high)
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
        let recorder = VideoFrameRecorder(recordingID: recordingID, outputURL: outputURL)

        let didClaimRecording = sessionQueue.sync {
            guard activeRecording == nil else {
                return false
            }
            activeRecording = recorder
            return true
        }
        guard didClaimRecording else {
            completion(.failure(PeekError.cameraBusy))
            return
        }

        video.setSampleBufferDelegate(recorder, queue: recorder.queue)

        completion(.success((recordingID, Date())))
    }

    func stopRecording(recordingID: UUID, completion: @escaping (Result<(URL, TimeInterval), Error>) -> Void) {
        let recorder = sessionQueue.sync { activeRecording }
        guard let recorder = recorder, recorder.recordingID == recordingID else {
            completion(.failure(PeekError.cameraNotAvailable))
            return
        }

        recorder.stop { [weak self] result in
            self?.sessionQueue.async {
                self?.videoOutput?.setSampleBufferDelegate(nil, queue: nil)
                self?.activeRecording = nil
                self?.stopSessionOnQueue()
                DispatchQueue.main.async {
                    completion(result)
                }
            }
        }
    }

    // MARK: - Frame Burst

    func captureFrames(count: Int, quality: Quality = .medium, completion: @escaping (Result<[Data], Error>) -> Void) {
        guard (1...30).contains(count) else {
            completion(.failure(PeekError.invalidArguments("count must be an integer from 1 through 30")))
            return
        }

        let shouldStopAfterCapture = session == nil

        do {
            try ensureSession(quality: quality)
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
            let captureID = UUID()

            let delegate = FrameCaptureDelegate { [weak self] result in
                self?.sessionQueue.async {
                    self?.frameDelegates.removeValue(forKey: captureID)
                }
                queue.async {
                    switch result {
                    case .success(let data):
                        frames.append(data)
                    case .failure:
                        break
                    }
                    pendingCount -= 1
                    if pendingCount == 0 {
                        let finalResult: Result<[Data], Error>
                        if frames.isEmpty {
                            finalResult = .failure(PeekError.encodingFailed)
                        } else {
                            finalResult = .success(frames)
                        }

                        self?.sessionQueue.async {
                            if shouldStopAfterCapture {
                                self?.stopSessionOnQueue()
                            }
                            DispatchQueue.main.async {
                                completion(finalResult)
                            }
                        }
                    }
                }
            }
            sessionQueue.sync {
                frameDelegates[captureID] = delegate
            }
            photo.capturePhoto(with: settings, delegate: delegate)
        }
    }

    // MARK: - Private Helpers

    private func ensureSession(quality: Quality = .medium) throws {
        let didStart = try startSessionIfNeeded(quality: quality)
        if didStart {
            waitForCameraWarmup()
        }
    }

    private func stopSessionOnQueue() {
        session?.stopRunning()
        session = nil
        captureDevice = nil
        selectedVideoDimensions = nil
        photoOutput = nil
        videoOutput?.setSampleBufferDelegate(nil, queue: nil)
        videoOutput = nil
        activeRecording = nil
    }

    private func configure(device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        if let format = preferredFullViewFormat(for: device) {
            device.activeFormat = format
        }
        selectedVideoDimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
    }

    private func preferredFullViewFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let landscapeFormats = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width >= dimensions.height
        }

        let fullViewFormats = landscapeFormats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let aspectRatio = Double(dimensions.width) / Double(dimensions.height)
            return aspectRatio >= 1.2 && aspectRatio <= 1.5
        }

        let candidates = fullViewFormats.isEmpty ? landscapeFormats : fullViewFormats
        return candidates.max { lhs, rhs in
            let lhsDimensions = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rhsDimensions = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return Int(lhsDimensions.width) * Int(lhsDimensions.height) < Int(rhsDimensions.width) * Int(rhsDimensions.height)
        }
    }

    private func waitForCameraWarmup() {
        Thread.sleep(forTimeInterval: 2.0)

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            guard let device = captureDevice else { return }
            if !device.isAdjustingExposure && !device.isAdjustingWhiteBalance {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
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

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

private final class VideoFrameRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let recordingID: UUID
    let outputURL: URL
    let queue = DispatchQueue(label: "com.peek.camera.video-recorder")

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var startTime: CMTime?
    private var lastTime: CMTime?
    private var isStopping = false
    private var stopCompletion: ((Result<(URL, TimeInterval), Error>) -> Void)?

    init(recordingID: UUID, outputURL: URL) {
        self.recordingID = recordingID
        self.outputURL = outputURL
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !isStopping else { return }

        do {
            if writer == nil {
                try startWriting(with: sampleBuffer)
            }

            guard let writer = writer,
                  let input = input,
                  writer.status == .writing,
                  input.isReadyForMoreMediaData else {
                return
            }

            if input.append(sampleBuffer) {
                lastTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            } else if let error = writer.error {
                finish(.failure(error))
            }
        } catch {
            finish(.failure(error))
        }
    }

    func stop(completion: @escaping (Result<(URL, TimeInterval), Error>) -> Void) {
        queue.async {
            self.isStopping = true
            self.stopCompletion = completion

            guard let writer = self.writer,
                  let input = self.input,
                  writer.status == .writing else {
                self.finish(.failure(PeekError.encodingFailed))
                return
            }

            input.markAsFinished()
            writer.finishWriting {
                if let error = writer.error {
                    self.finish(.failure(error))
                    return
                }

                let duration: TimeInterval
                if let startTime = self.startTime, let lastTime = self.lastTime {
                    duration = max(0, CMTimeGetSeconds(lastTime - startTime))
                } else {
                    duration = 0
                }
                self.finish(.success((self.outputURL, duration)))
            }
        }
    }

    private func startWriting(with sampleBuffer: CMSampleBuffer) throws {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw PeekError.encodingFailed
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(dimensions.width),
            AVVideoHeightKey: Int(dimensions.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw PeekError.encodingFailed
        }

        writer.add(input)
        let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        writer.startWriting()
        writer.startSession(atSourceTime: startTime)

        self.writer = writer
        self.input = input
        self.startTime = startTime
    }

    private func finish(_ result: Result<(URL, TimeInterval), Error>) {
        guard let completion = stopCompletion else { return }
        stopCompletion = nil
        completion(result)
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
