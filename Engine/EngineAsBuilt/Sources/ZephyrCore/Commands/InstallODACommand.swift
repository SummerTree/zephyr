import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ImGui
import SwiftSDL
import CSDL3


private struct ODADownloadUpdate: Sendable {
    let progress: Float?
    let downloadedBytes: Int64
    let expectedBytes: Int64
    let bytesPerSecond: Double
    let status: String?
}

#if os(Windows)
private final class ODADownloadOperation: @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (ODADownloadUpdate) async -> Void
    private let lock = NSLock()

    private var process: Process?
    private var cancelFile: URL?

    init(
        destination: URL,
        onProgress: @escaping @Sendable (ODADownloadUpdate) async -> Void
    ) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func download(from url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await performDownload(from: url)
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        let (process, cancelFile) = lock.withLock {
            (self.process, self.cancelFile)
        }

        if let cancelFile {
            _ = FileManager.default.createFile(
                atPath: cancelFile.path,
                contents: Data()
            )
        }

        guard let process, process.isRunning else { return }
        process.terminate()

        let windowsDirectory = ProcessInfo.processInfo.environment["WINDIR"] ?? "C:\\Windows"
        let taskkill = windowsDirectory
            .trimmingCharacters(in: CharacterSet(charactersIn: "\\/"))
            + "\\System32\\taskkill.exe"
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: taskkill)
        killer.arguments = [
            "/PID", String(process.processIdentifier),
            "/T", "/F",
        ]
        killer.standardOutput = FileHandle.nullDevice
        killer.standardError = FileHandle.nullDevice
        try? killer.run()
    }

    private func performDownload(from url: URL) async throws -> URL {
        let fileManager = FileManager.default
        let token = UUID().uuidString
        let scriptFile = fileManager.temporaryDirectory
            .appendingPathComponent("oda-download-\(token).ps1")
        let progressFile = fileManager.temporaryDirectory
            .appendingPathComponent("oda-download-\(token).progress")
        let cancelFile = fileManager.temporaryDirectory
            .appendingPathComponent("oda-download-\(token).cancel")
        let outputFile = fileManager.temporaryDirectory
            .appendingPathComponent("oda-download-\(token).out")
        let errorFile = fileManager.temporaryDirectory
            .appendingPathComponent("oda-download-\(token).err")

        try? fileManager.removeItem(at: destination)
        try? fileManager.removeItem(at: progressFile)
        try? fileManager.removeItem(at: cancelFile)

        try Self.powerShellScript.write(
            to: scriptFile,
            atomically: true,
            encoding: .utf8
        )

        guard fileManager.createFile(atPath: outputFile.path, contents: nil),
              fileManager.createFile(atPath: errorFile.path, contents: nil) else {
            throw NSError(
                domain: "InstallODA",
                code: -10,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Unable to create temporary downloader files."
                ]
            )
        }

        let outputHandle = try FileHandle(forWritingTo: outputFile)
        let errorHandle = try FileHandle(forWritingTo: errorFile)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
            try? fileManager.removeItem(at: scriptFile)
            try? fileManager.removeItem(at: progressFile)
            try? fileManager.removeItem(at: cancelFile)
            try? fileManager.removeItem(at: outputFile)
            try? fileManager.removeItem(at: errorFile)
        }

        let windowsDirectory = ProcessInfo.processInfo.environment["WINDIR"] ?? "C:\\Windows"
        let powerShell = windowsDirectory
            .trimmingCharacters(in: CharacterSet(charactersIn: "\\/"))
            + "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: powerShell)
        process.arguments = [
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy", "Bypass",
            "-File", scriptFile.path,
            "-Url", url.absoluteString,
            "-Destination", destination.path,
            "-ProgressFile", progressFile.path,
            "-CancelFile", cancelFile.path,
        ]
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        lock.withLock {
            self.process = process
            self.cancelFile = cancelFile
        }

        defer {
            lock.withLock {
                if self.process === process {
                    self.process = nil
                    self.cancelFile = nil
                }
            }
        }

        print("[InstallODA] PowerShell downloader: \(powerShell)")

        do {
            try process.run()
        } catch {
            throw NSError(
                domain: "InstallODA",
                code: -11,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Unable to launch the Windows downloader: \(error.localizedDescription)"
                ]
            )
        }

        var lastReportedBytes: Int64 = 0
        var lastSampleBytes: Int64 = 0
        var lastSampleDate = Date()
        var calculatedSpeed = 0.0
        var lastProgressUpdate = Date.distantPast
        var expectedBytes: Int64 = -1

        do {
            while process.isRunning {
                try Task.checkCancellation()

                let parsed = Self.readProgressFile(progressFile)
                if let total = parsed?.expectedBytes, total > 0 {
                    expectedBytes = total
                }

                let fileBytes = Self.fileSize(destination)
                let downloadedBytes = max(fileBytes, parsed?.downloadedBytes ?? 0)
                let now = Date()
                let elapsed = now.timeIntervalSince(lastSampleDate)

                if elapsed >= 0.25 {
                    calculatedSpeed = Double(max(0, downloadedBytes - lastSampleBytes)) / elapsed
                    lastSampleBytes = downloadedBytes
                    lastSampleDate = now
                }

                if now.timeIntervalSince(lastProgressUpdate) >= 0.20
                    || downloadedBytes != lastReportedBytes {
                    let progress: Float? = expectedBytes > 0
                        ? Float(Double(downloadedBytes) / Double(expectedBytes))
                        : nil
                    let speed = max(calculatedSpeed, parsed?.bytesPerSecond ?? 0)

                    await onProgress(ODADownloadUpdate(
                        progress: progress,
                        downloadedBytes: downloadedBytes,
                        expectedBytes: expectedBytes,
                        bytesPerSecond: speed,
                        status: parsed?.message
                    ))

                    if let message = parsed?.message, !message.isEmpty,
                       downloadedBytes == 0 {
                        print("[InstallODA] \(message)")
                    }

                    lastReportedBytes = downloadedBytes
                    lastProgressUpdate = now
                }

                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try Task.checkCancellation()
        } catch {
            cancel()
            try? fileManager.removeItem(at: destination)
            throw error
        }

        try? outputHandle.synchronize()
        try? errorHandle.synchronize()

        let errorOutput = (try? String(
            contentsOf: errorFile,
            encoding: .utf8
        ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus == 1223 {
            try? fileManager.removeItem(at: destination)
            throw CancellationError()
        }

        guard process.terminationStatus == 0 else {
            try? fileManager.removeItem(at: destination)
            let message = errorOutput.isEmpty
                ? "Windows downloader exited with code \(process.terminationStatus)."
                : errorOutput
            throw NSError(
                domain: "InstallODA",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        let finalSize = Self.fileSize(destination)
        guard finalSize > 0 else {
            throw NSError(
                domain: "InstallODA",
                code: -12,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The Windows downloader completed without producing a file."
                ]
            )
        }

        await onProgress(ODADownloadUpdate(
            progress: 1,
            downloadedBytes: finalSize,
            expectedBytes: finalSize,
            bytesPerSecond: calculatedSpeed,
            status: "Download complete."
        ))

        return destination
    }

    private struct ProgressRecord {
        let downloadedBytes: Int64
        let expectedBytes: Int64
        let bytesPerSecond: Double
        let message: String
    }

    private static func readProgressFile(_ url: URL) -> ProgressRecord? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(
                separator: "|",
                maxSplits: 4,
                omittingEmptySubsequences: false
            )
        guard fields.count >= 5 else { return nil }

        return ProgressRecord(
            downloadedBytes: Int64(fields[1]) ?? 0,
            expectedBytes: Int64(fields[2]) ?? -1,
            bytesPerSecond: Double(fields[3]) ?? 0,
            message: String(fields[4])
        )
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ) else {
            return 0
        }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static let powerShellScript = #"""
param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$Destination,
    [Parameter(Mandatory = $true)][string]$ProgressFile,
    [Parameter(Mandatory = $true)][string]$CancelFile
)

$ErrorActionPreference = 'Stop'
$client = $null
$handler = $null
$response = $null
$stream = $null
$output = $null
$headerCancellation = $null

function Write-DownloadState {
    param(
        [string]$State,
        [long]$Downloaded,
        [long]$Total,
        [double]$Speed,
        [string]$Message
    )

    $safeMessage = ($Message -replace '\|', '/') -replace '[\r\n]+', ' '
    $record = '{0}|{1}|{2}|{3}|{4}' -f $State, $Downloaded, $Total, $Speed, $safeMessage
    [System.IO.File]::WriteAllText(
        $ProgressFile,
        $record,
        ([System.Text.UTF8Encoding]::new($false))
    )
}

try {
    Add-Type -AssemblyName System.Net.Http
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

    Write-DownloadState 'connecting' 0 -1 0 'Connecting to Open Design Alliance...'

    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    $handler.UseProxy = $true
    $handler.Proxy = [System.Net.WebRequest]::DefaultWebProxy
    if ($null -ne $handler.Proxy) {
        $handler.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
    }

    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan

    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
    [void]$request.Headers.TryAddWithoutValidation('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) ZephyrCAD/1.0')
    [void]$request.Headers.TryAddWithoutValidation('Cache-Control', 'no-cache')
    [void]$request.Headers.TryAddWithoutValidation('Pragma', 'no-cache')

    $headerCancellation = New-Object System.Threading.CancellationTokenSource
    $headerCancellation.CancelAfter([TimeSpan]::FromSeconds(45))
    $response = $client.SendAsync(
        $request,
        [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead,
        $headerCancellation.Token
    ).GetAwaiter().GetResult()
    $response.EnsureSuccessStatusCode()

    $total = -1L
    if ($response.Content.Headers.ContentLength.HasValue) {
        $total = [long]$response.Content.Headers.ContentLength.Value
    }

    $finalHost = $response.RequestMessage.RequestUri.Host
    Write-DownloadState 'downloading' 0 $total 0 ("Downloading from {0}..." -f $finalHost)

    $destinationDirectory = [System.IO.Path]::GetDirectoryName($Destination)
    [System.IO.Directory]::CreateDirectory($destinationDirectory) | Out-Null

    $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    if ($stream.CanTimeout) {
        $stream.ReadTimeout = 30000
    }

    $output = [System.IO.FileStream]::new(
        $Destination,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::Read
    )

    $buffer = [byte[]]::new(1024 * 1024)
    $downloaded = 0L
    $lastBytes = 0L
    $lastReport = [System.Diagnostics.Stopwatch]::StartNew()

    while ($true) {
        if (Test-Path -LiteralPath $CancelFile) {
            throw [System.OperationCanceledException]::new('Download cancelled.')
        }

        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) {
            break
        }

        $output.Write($buffer, 0, $read)
        $downloaded += $read

        if ($lastReport.ElapsedMilliseconds -ge 200) {
            $seconds = [Math]::Max($lastReport.Elapsed.TotalSeconds, 0.001)
            $speed = ($downloaded - $lastBytes) / $seconds
            Write-DownloadState 'downloading' $downloaded $total $speed ("Downloading from {0}..." -f $finalHost)
            $lastBytes = $downloaded
            $lastReport.Restart()
        }
    }

    $output.Flush($true)
    Write-DownloadState 'complete' $downloaded $downloaded 0 'Download complete.'
    exit 0
}
catch [System.OperationCanceledException] {
    Write-DownloadState 'cancelled' 0 -1 0 'Download cancelled.'
    exit 1223
}
catch {
    [Console]::Error.WriteLine($_.Exception.ToString())
    exit 1
}
finally {
    if ($null -ne $output) { $output.Dispose() }
    if ($null -ne $stream) { $stream.Dispose() }
    if ($null -ne $response) { $response.Dispose() }
    if ($null -ne $client) { $client.Dispose() }
    if ($null -ne $handler) { $handler.Dispose() }
    if ($null -ne $headerCancellation) { $headerCancellation.Dispose() }
}
"""#
}
#else
private final class ODADownloadOperation: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (ODADownloadUpdate) async -> Void
    private let lock = NSLock()

    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var downloadedResult: Result<URL, Error>?
    private var completed = false
    private var lastBytes: Int64 = 0
    private var lastSpeed: Double = 0
    private var lastSample = Date()

    init(
        destination: URL,
        onProgress: @escaping @Sendable (ODADownloadUpdate) async -> Void
    ) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func download(from url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if completed {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                lock.unlock()

                let configuration = URLSessionConfiguration.ephemeral
                configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 60 * 30
                configuration.httpMaximumConnectionsPerHost = 2

                let delegateQueue = OperationQueue()
                delegateQueue.name = "Zephyr.ODADownload"
                delegateQueue.maxConcurrentOperationCount = 1

                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: delegateQueue
                )

                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                request.timeoutInterval = 60
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                request.setValue("no-cache", forHTTPHeaderField: "Pragma")
                request.setValue("ZephyrCAD/1.0", forHTTPHeaderField: "User-Agent")

                let task = session.downloadTask(with: request)

                lock.lock()
                if completed {
                    lock.unlock()
                    task.cancel()
                    session.invalidateAndCancel()
                    return
                }
                self.session = session
                self.task = task
                lock.unlock()

                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        let task = self.task
        let session = self.session
        self.continuation = nil
        self.task = nil
        self.session = nil
        lock.unlock()

        task?.cancel()
        session?.invalidateAndCancel()
        try? FileManager.default.removeItem(at: destination)
        continuation?.resume(throwing: CancellationError())
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = Date()

        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        let elapsed = now.timeIntervalSince(lastSample)
        if elapsed >= 0.20 {
            lastSpeed = Double(max(0, totalBytesWritten - lastBytes)) / elapsed
            lastBytes = totalBytesWritten
            lastSample = now
        }
        let speed = lastSpeed
        lock.unlock()

        let progress: Float? = totalBytesExpectedToWrite > 0
            ? Float(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
            : nil

        let update = ODADownloadUpdate(
            progress: progress,
            downloadedBytes: totalBytesWritten,
            expectedBytes: totalBytesExpectedToWrite,
            bytesPerSecond: speed,
            status: nil
        )

        Task {
            await onProgress(update)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock()
            downloadedResult = .success(destination)
            lock.unlock()
        } catch {
            lock.lock()
            downloadedResult = .failure(error)
            lock.unlock()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }

        if let response = task.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            try? FileManager.default.removeItem(at: destination)
            finish(.failure(NSError(
                domain: "InstallODA",
                code: response.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "ODA download failed with HTTP status \(response.statusCode)."
                ]
            )))
            return
        }

        lock.lock()
        let result = downloadedResult
        lock.unlock()

        finish(result ?? .failure(NSError(
            domain: "InstallODA",
            code: -5,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The ODA download ended without producing a file."
            ]
        )))
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        let session = self.session
        self.continuation = nil
        self.task = nil
        self.session = nil
        lock.unlock()

        session?.finishTasksAndInvalidate()

        switch result {
        case .success(let url):
            continuation?.resume(returning: url)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}
#endif
@MainActor
public final class InstallODACommand: FeatureCommand {

    private enum State {
        case showingAgreement
        case downloading
        case installing
        case finished(success: Bool, message: String)
    }

    private var state: State = .showingAgreement
    private var agreed = false
    private var downloadProgress: Float = 0
    private var hasDeterminateProgress = false
    private var downloadSpeed = ""
    private var statusText = ""
    private var installTask: Task<Void, Never>?
    private var activeDownload: ODADownloadOperation?
    private var activeProcess: Process?
    private var installGeneration = UUID()
    private var modalOpened = false
    private var okClicked = false

    private static let fallbackURLs: [String: String] = [
        "windows": "https://www.opendesign.com/guestfiles/get?filename=ODAFileConverter_QT6_vc16_amd64dll_27.1.msi",
        "macos_arm64": "https://www.opendesign.com/guestfiles/get?filename=ODAFileConverter_QT6_macOsX_arm64_15.0dll_27.1.dmg",
        "macos_x64": "https://www.opendesign.com/guestfiles/get?filename=ODAFileConverter_QT6_macOsX_x64_15.0dll_27.1.dmg",
    ]

    private static let agreementURL = "https://www.opendesign.com/agreements/2025/en/ODA%20Community%20User%20Agreement%2009-2025.pdf"

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        stopActiveInstall()
        state = .showingAgreement
        agreed = false
        downloadProgress = 0
        hasDeterminateProgress = false
        downloadSpeed = ""
        statusText = ""
        modalOpened = false
        okClicked = false
        processor.commandPrompt = "ODA FileConverter installation."
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        stopActiveInstall()
        state = .showingAgreement
        processor.commandPrompt = nil
    }

    public func handleMouseClick(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        if okClicked {
            okClicked = false
            processor.commandPrompt = nil
            return .finished
        }
        return .continue
    }

    public func handleMouseMotion(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        if okClicked {
            okClicked = false
            processor.commandPrompt = nil
            return .finished
        }
        return .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
    public var isSnappingEnabled: Bool { false }
    public func getDrawingSnapPoints() -> [Vector3] { [] }

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        .continue
    }

    public func renderImGui(engine: PhrostEngine) {
        let id = "ODA FileConverter##InstallODA"
        if !modalOpened {
            ImGuiOpenPopup(id, Int32(ImGuiPopupFlags_None.rawValue))
            modalOpened = true
        }

        let io = ImGuiGetIO()!
        let displayWidth = io.pointee.DisplaySize.x
        let displayHeight = io.pointee.DisplaySize.y
        let desiredSize: ImVec2

        switch state {
        case .showingAgreement:
            desiredSize = ImVec2(
                x: min(ImGuiGetFontSize() * 52, displayWidth * 0.70),
                y: min(ImGuiGetFontSize() * 34, displayHeight * 0.70)
            )
        case .downloading, .installing:
            desiredSize = ImVec2(
                x: min(ImGuiGetFontSize() * 42, displayWidth * 0.70),
                y: min(ImGuiGetFontSize() * 13, displayHeight * 0.70)
            )
        case .finished:
            desiredSize = ImVec2(
                x: min(ImGuiGetFontSize() * 42, displayWidth * 0.70),
                y: min(ImGuiGetFontSize() * 10, displayHeight * 0.70)
            )
        }

        ImGuiSetNextWindowPos(
            ImVec2(
                x: (displayWidth - desiredSize.x) * 0.5,
                y: (displayHeight - desiredSize.y) * 0.5
            ),
            Int32(ImGuiCond_Always.rawValue),
            ImVec2(x: 0, y: 0)
        )
        ImGuiSetNextWindowSize(desiredSize, Int32(ImGuiCond_Always.rawValue))

        let flags = Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)
            | Int32(ImGuiWindowFlags_NoResize.rawValue)
            | Int32(ImGuiWindowFlags_NoCollapse.rawValue)
            | Int32(ImGuiWindowFlags_NoMove.rawValue)

        var open = true
        guard ImGuiBeginPopupModal(id, &open, flags) else { return }
        defer { ImGuiEndPopup() }

        switch state {
        case .showingAgreement:
            renderAgreementContent()
        case .downloading:
            renderDownloadContent()
        case .installing:
            renderInstallContent()
        case .finished(let success, let message):
            renderFinishedContent(success: success, message: message)
        }
    }

    private func renderAgreementContent() {
        ImGuiTextV("ODA FileConverter Installation")
        ImGuiSpacing()
        ImGuiSeparator()
        ImGuiSpacing()
        ImGuiTextWrappedV("The ODA FileConverter converts between DWG and DXF formats. It is required to open and save AutoCAD DWG files.")
        ImGuiSpacing()
        ImGuiTextWrappedV("To use this software, you must accept the ODA Community User Agreement.")
        ImGuiSpacing()

        if ImGuiButton("View Agreement (opens in browser)", ImVec2(x: 0, y: 0)) {
            _ = Self.agreementURL.withCString { SDL_OpenURL($0) }
        }

        ImGuiSpacing()
        ImGuiSeparator()
        ImGuiSpacing()
        ImGuiCheckbox("I agree to the ODA Community User Agreement", &agreed)
        ImGuiSpacing()

        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ODAFileConverter")
            .path ?? "Application Support/ODAFileConverter"

        ImGuiTextV("Install location:")
        ImGuiSameLine(0, -1)
        ImGuiTextDisabledV(directory)
        ImGuiSpacing()
        ImGuiSeparator()
        ImGuiSpacing()

        if !agreed {
            ImGuiPushStyleVar(Int32(ImGuiStyleVar_Alpha.rawValue), Float(0.5))
            ImGuiButton("Install", ImVec2(x: 120, y: 0))
            ImGuiPopStyleVar(1)
            ImGuiSameLine(0, -1)
            ImGuiTextDisabledV("(you must agree first)")
        } else if ImGuiButton("Install", ImVec2(x: 120, y: 0)) {
            startInstall()
        }

        ImGuiSameLine(0, -1)
        if ImGuiButton("Cancel", ImVec2(x: 120, y: 0)) {
            state = .finished(success: false, message: "Cancelled.")
        }
    }

    private func renderDownloadContent() {
        ImGuiTextV("Downloading ODA FileConverter...")
        ImGuiSpacing()

        if hasDeterminateProgress {
            ImGuiProgressBar(downloadProgress, ImVec2(x: 0, y: 0), nil)
        } else {
            ImGuiProgressBar(-1, ImVec2(x: 0, y: 0), nil)
        }

        ImGuiSpacing()
        if !statusText.isEmpty { ImGuiTextV(statusText) }
        if !downloadSpeed.isEmpty { ImGuiTextV(downloadSpeed) }
        ImGuiSpacing()

        if ImGuiButton("Cancel", ImVec2(x: 120, y: 0)) {
            cancelInstallFromUI()
        }
    }

    private func renderInstallContent() {
        ImGuiTextV("Installing ODA FileConverter...")
        ImGuiSpacing()
        ImGuiProgressBar(-1, ImVec2(x: 0, y: 0), nil)
        ImGuiSpacing()
        if !statusText.isEmpty { ImGuiTextV(statusText) }
    }

    private func renderFinishedContent(success: Bool, message: String) {
        if success {
            ImGuiTextColoredV(
                ImVec4(x: 0.2, y: 0.9, z: 0.3, w: 1),
                "Installation Complete!"
            )
        } else if message == "Cancelled." {
            ImGuiTextColoredV(
                ImVec4(x: 0.9, y: 0.7, z: 0.2, w: 1),
                "Installation Cancelled"
            )
        } else {
            ImGuiTextColoredV(
                ImVec4(x: 0.9, y: 0.3, z: 0.3, w: 1),
                "Installation Failed"
            )
        }

        ImGuiSpacing()
        ImGuiTextWrappedV(message)
        ImGuiSpacing()
        ImGuiSpacing()

        if ImGuiButton("OK", ImVec2(x: 120, y: 0)) {
            stopActiveInstall()
            okClicked = true
            modalOpened = false
            ImGuiCloseCurrentPopup()
        }
    }

    private func startInstall() {
        stopActiveInstall()

        let baseURL: URL
        do {
            baseURL = try resolveURL()
        } catch {
            state = .finished(success: false, message: error.localizedDescription)
            return
        }

        let requestURL = Self.cacheBustedURL(baseURL)
        let temporaryFile = Self.temporaryDownloadURL(for: baseURL)
        let generation = UUID()
        installGeneration = generation
        state = .downloading
        statusText = "Connecting to Open Design Alliance..."
        downloadProgress = 0
        hasDeterminateProgress = false
        downloadSpeed = ""

        let download = ODADownloadOperation(
            destination: temporaryFile,
            onProgress: { [weak self] update in
                await self?.applyDownloadUpdate(update, generation: generation)
            }
        )
        activeDownload = download

        print("[InstallODA] Downloading \(requestURL.absoluteString)")
        print("[InstallODA] To: \(temporaryFile.path)")

        installTask = Task.detached(priority: .userInitiated) { [weak self, download] in
            guard let self else { return }

            do {
                let file = try await download.download(from: requestURL)
                defer { try? FileManager.default.removeItem(at: file) }

                #if os(Windows)
                try Self.validateMSI(at: file)
                #endif

                try Task.checkCancellation()
                guard await self.beginInstalling(generation: generation) else {
                    throw CancellationError()
                }

                let installedPath = try await Self.runInstall(
                    file: file,
                    onProcess: { [weak self] process in
                        await self?.setActiveProcess(process, generation: generation)
                    },
                    onStatus: { [weak self] status in
                        await self?.applyInstallStatus(status, generation: generation)
                    }
                )

                try Task.checkCancellation()
                UserDefaults.standard.set(installedPath, forKey: "ODAFileConverterPath")
                await self.completeInstall(
                    generation: generation,
                    success: true,
                    message: "ODA FileConverter installed. You can now open and save DWG files."
                )
            } catch is CancellationError {
                await self.completeInstall(
                    generation: generation,
                    success: false,
                    message: "Cancelled."
                )
            } catch {
                await self.completeInstall(
                    generation: generation,
                    success: false,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func cancelInstallFromUI() {
        stopActiveInstall()
        statusText = ""
        downloadSpeed = ""
        state = .finished(success: false, message: "Cancelled.")
    }

    private func stopActiveInstall() {
        installGeneration = UUID()

        let download = activeDownload
        activeDownload = nil
        download?.cancel()

        let process = activeProcess
        activeProcess = nil
        if let process, process.isRunning {
            process.terminate()
        }

        let task = installTask
        installTask = nil
        task?.cancel()
    }

    private func setActiveProcess(_ process: Process?, generation: UUID) {
        guard installGeneration == generation else {
            if let process, process.isRunning {
                process.terminate()
            }
            return
        }
        activeProcess = process
    }

    private func applyDownloadUpdate(_ update: ODADownloadUpdate, generation: UUID) {
        guard installGeneration == generation else { return }

        if let progress = update.progress {
            hasDeterminateProgress = true
            downloadProgress = max(0, min(progress, 1))
        }

        if update.downloadedBytes == 0,
           let status = update.status,
           !status.isEmpty {
            statusText = status
        } else if update.expectedBytes > 0 {
            statusText = "\(Self.formatBytes(update.downloadedBytes)) of \(Self.formatBytes(update.expectedBytes))"
        } else {
            statusText = "\(Self.formatBytes(update.downloadedBytes)) downloaded"
        }
        downloadSpeed = update.bytesPerSecond > 0
            ? Self.formatSpeed(update.bytesPerSecond)
            : ""
    }

    private func beginInstalling(generation: UUID) -> Bool {
        guard installGeneration == generation else { return false }
        activeDownload = nil
        activeProcess = nil
        state = .installing
        statusText = "Preparing installer..."
        downloadSpeed = ""
        return true
    }

    private func applyInstallStatus(_ status: String, generation: UUID) {
        guard installGeneration == generation else { return }
        statusText = status
    }

    private func completeInstall(
        generation: UUID,
        success: Bool,
        message: String
    ) {
        guard installGeneration == generation else { return }
        activeDownload = nil
        activeProcess = nil
        installTask = nil
        state = .finished(success: success, message: message)
    }

    private func resolveURL() throws -> URL {
        #if os(Windows)
        let key = "windows"
        #elseif os(macOS)
        #if arch(arm64)
        let key = "macos_arm64"
        #else
        let key = "macos_x64"
        #endif
        #else
        throw NSError(
            domain: "InstallODA",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Unsupported platform"]
        )
        #endif

        guard let string = Self.fallbackURLs[key], let url = URL(string: string) else {
            throw NSError(
                domain: "InstallODA",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "No download URL is configured for \(key)."]
            )
        }
        return url
    }

    nonisolated private static func cacheBustedURL(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.removeAll {
            $0.name.caseInsensitiveCompare("zephyrCacheBust") == .orderedSame
        }
        queryItems.append(URLQueryItem(
            name: "zephyrCacheBust",
            value: String(Int(Date().timeIntervalSince1970))
        ))
        components?.queryItems = queryItems
        return components?.url ?? url
    }

    nonisolated private static func temporaryDownloadURL(for url: URL) -> URL {
        let filename = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first {
                $0.name.caseInsensitiveCompare("filename") == .orderedSame
            }?
            .value ?? url.lastPathComponent
        let safeFilename = filename.isEmpty
            ? "ODAFileConverter.download"
            : filename
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(safeFilename)")
    }

    nonisolated private static func validateMSI(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 8) ?? Data()
        let expected = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])

        guard header == expected else {
            throw NSError(
                domain: "InstallODA",
                code: -9,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Open Design Alliance returned a file that is not a valid MSI installer. The download may have been an expired redirect or an HTML error page."
                ]
            )
        }
    }


    nonisolated private static func runInstall(
        file: URL,
        onProcess: @escaping @Sendable (Process?) async -> Void,
        onStatus: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw NSError(
                domain: "InstallODA",
                code: -3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "No Application Support directory is available."
                ]
            )
        }

        let target = applicationSupport.appendingPathComponent("ODAFileConverter")
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: true
        )

        #if os(Windows)
        await onStatus("Extracting ODA FileConverter...")
        let windowsDirectory = ProcessInfo.processInfo.environment["WINDIR"] ?? "C:\\Windows"
        let msiexec = windowsDirectory
            .trimmingCharacters(in: CharacterSet(charactersIn: "\\/"))
            + "\\System32\\msiexec.exe"

        _ = try await run(
            exe: msiexec,
            args: [
                "/a",
                file.path,
                "/qn",
                "/norestart",
                "TARGETDIR=\(target.path)",
            ],
            successfulExitCodes: [0, 1641, 3010],
            onProcess: onProcess
        )

        guard let converter = findConverter(
            in: target,
            filename: "ODAFileConverter.exe"
        ) else {
            throw NSError(
                domain: "InstallODA",
                code: -7,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The MSI completed, but ODAFileConverter.exe was not found under \(target.path)."
                ]
            )
        }
        return converter.path
        #elseif os(macOS)
        await onStatus("Mounting disk image...")
        let output = try await run(
            exe: "/usr/bin/hdiutil",
            args: ["attach", file.path, "-nobrowse", "-plist"],
            onProcess: onProcess
        )

        let mountPoint: String
        if let data = output.data(using: .utf8),
           let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
           ) as? [String: Any],
           let entities = propertyList["system-entities"] as? [[String: Any]],
           let mounted = entities.compactMap({ $0["mount-point"] as? String }).first {
            mountPoint = mounted
        } else {
            mountPoint = "/Volumes/ODAFileConverter"
        }

        defer {
            _ = try? Process.run(
                URL(fileURLWithPath: "/usr/bin/hdiutil"),
                arguments: ["detach", mountPoint]
            )
        }

        await onStatus("Copying ODA FileConverter...")
        let source = URL(fileURLWithPath: "\(mountPoint)/ODAFileConverter.app")
        let destination = target.appendingPathComponent("ODAFileConverter.app")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)

        await onStatus("Clearing quarantine...")
        _ = try? await run(
            exe: "/usr/bin/xattr",
            args: ["-r", "-d", "com.apple.quarantine", destination.path],
            onProcess: onProcess
        )
        return destination
            .appendingPathComponent("Contents/MacOS/ODAFileConverter")
            .path
        #else
        throw NSError(
            domain: "InstallODA",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Unsupported platform"]
        )
        #endif
    }

    nonisolated private static func findConverter(
        in root: URL,
        filename: String
    ) -> URL? {
        let fileManager = FileManager.default
        if root.lastPathComponent.caseInsensitiveCompare(filename) == .orderedSame,
           fileManager.fileExists(atPath: root.path) {
            return root
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }

        var matches: [URL] = []
        for case let candidate as URL in enumerator {
            if candidate.lastPathComponent.caseInsensitiveCompare(filename) == .orderedSame {
                matches.append(candidate)
            }
        }
        return matches.min { $0.path.count < $1.path.count }
    }

    @discardableResult
    nonisolated private static func run(
        exe: String,
        args: [String],
        successfulExitCodes: Set<Int32> = [0],
        onProcess: @escaping @Sendable (Process?) async -> Void
    ) async throws -> String {
        let fileManager = FileManager.default
        let outputFile = fileManager.temporaryDirectory
            .appendingPathComponent("oda-process-\(UUID().uuidString).out")
        let errorFile = fileManager.temporaryDirectory
            .appendingPathComponent("oda-process-\(UUID().uuidString).err")

        guard fileManager.createFile(atPath: outputFile.path, contents: nil),
              fileManager.createFile(atPath: errorFile.path, contents: nil) else {
            throw NSError(
                domain: "InstallODA",
                code: -8,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Unable to create temporary process output files."
                ]
            )
        }

        let outputHandle = try FileHandle(forWritingTo: outputFile)
        let errorHandle = try FileHandle(forWritingTo: errorFile)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
            try? fileManager.removeItem(at: outputFile)
            try? fileManager.removeItem(at: errorFile)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        print("[InstallODA] \(exe) \(args.joined(separator: " "))")

        do {
            try process.run()
        } catch {
            throw NSError(
                domain: "InstallODA",
                code: -8,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Unable to launch \(exe): \(error.localizedDescription)"
                ]
            )
        }

        await onProcess(process)

        do {
            while process.isRunning {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try Task.checkCancellation()
        } catch {
            if process.isRunning {
                process.terminate()
            }
            await onProcess(nil)
            throw error
        }

        await onProcess(nil)
        try? outputHandle.synchronize()
        try? errorHandle.synchronize()

        let output = (try? String(contentsOf: outputFile, encoding: .utf8)) ?? ""
        let errorOutput = (try? String(contentsOf: errorFile, encoding: .utf8)) ?? ""

        guard successfulExitCodes.contains(process.terminationStatus) else {
            let detail = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = detail.isEmpty
                ? "\(URL(fileURLWithPath: exe).lastPathComponent) exited with code \(process.terminationStatus)."
                : detail
            print("[InstallODA] FAILED: \(message)")
            throw NSError(
                domain: "InstallODA",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        return output
    }

    nonisolated private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    nonisolated private static func formatSpeed(_ bytesPerSecond: Double) -> String {
        "\(formatBytes(Int64(bytesPerSecond)))/s"
    }
}
