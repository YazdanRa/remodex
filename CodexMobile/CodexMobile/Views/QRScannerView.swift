// FILE: QRScannerView.swift
// Purpose: AVFoundation camera-based QR scanner for relay session pairing.
// Layer: View
// Exports: QRScannerView
// Depends on: SwiftUI, AVFoundation

import AVFoundation
import SwiftUI

struct QRScannerView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openURL) private var openURL

    let onScan: (CodexPairingQRPayload) -> Void

    @State private var scannerError: String?
    @State private var hasCameraPermission = false
    @State private var isCheckingPermission = true

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                if isCheckingPermission {
                    ProgressView()
                        .tint(.white)
                } else if hasCameraPermission {
                    QRCameraPreview { code, resetScanLock in
                        handleScanResult(code, resetScanLock: resetScanLock)
                    }
                    .ignoresSafeArea()

                    scannerOverlay(for: geometry.size.width)
                } else {
                    cameraPermissionView(for: geometry.size.width)
                }
            }
        }
        .task {
            await checkCameraPermission()
        }
        .alert("Scan Error", isPresented: Binding(
            get: { scannerError != nil },
            set: { if !$0 { scannerError = nil } }
        )) {
            Button("OK", role: .cancel) { scannerError = nil }
        } message: {
            Text(scannerError ?? "Invalid QR code")
        }
    }

    private func scannerOverlay(for availableWidth: CGFloat) -> some View {
        let frameSize = scannerFrameSize(for: availableWidth)

        return VStack(spacing: 24) {
            Spacer()

            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.6), lineWidth: 2)
                .frame(width: frameSize, height: frameSize)

            Text("Scan QR code from Remodex CLI")
                .font(AppFont.subheadline(weight: .medium))
                .foregroundStyle(.white)

            Spacer()
        }
    }

    private func cameraPermissionView(for availableWidth: CGFloat) -> some View {
        let maxWidth = permissionContentWidth(for: availableWidth)

        return VStack(spacing: 20) {
            Image(systemName: "camera.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Camera access needed")
                .font(AppFont.title3(weight: .semibold))
                .foregroundStyle(.white)

            Text("Open Settings and allow camera access to scan the pairing QR code.")
                .font(AppFont.subheadline())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("Open Settings") {
                if let url = URL(string: "app-settings:") {
                    openURL(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: maxWidth)
        .padding(.horizontal, 24)
    }

    private var usesRegularPadLayout: Bool {
        horizontalSizeClass == .regular
    }

    private func scannerFrameSize(for availableWidth: CGFloat) -> CGFloat {
        usesWidePadLayout(for: availableWidth) ? 320 : 250
    }

    private func permissionContentWidth(for availableWidth: CGFloat) -> CGFloat {
        usesWidePadLayout(for: availableWidth) ? 460 : 360
    }

    private func usesWidePadLayout(for availableWidth: CGFloat) -> Bool {
        usesRegularPadLayout && availableWidth >= 900
    }

    private func checkCameraPermission() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            hasCameraPermission = true
        case .notDetermined:
            hasCameraPermission = await AVCaptureDevice.requestAccess(for: .video)
        default:
            hasCameraPermission = false
        }
        isCheckingPermission = false
    }

    private func handleScanResult(_ code: String, resetScanLock: @escaping () -> Void) {
        guard let data = code.data(using: .utf8) else {
            scannerError = "QR code contains invalid text encoding."
            resetScanLock()
            return
        }

        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(CodexPairingQRPayload.self, from: data) else {
            scannerError = "Not a valid secure pairing code. Make sure you're scanning a QR from the latest Remodex bridge."
            resetScanLock()
            return
        }

        guard payload.v == codexPairingQRVersion else {
            scannerError = "This QR code uses an unsupported pairing format. Update the iPhone app or the Mac bridge and try again."
            resetScanLock()
            return
        }

        guard !payload.relay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            scannerError = "QR code is missing the relay URL. Re-generate the code from the bridge."
            resetScanLock()
            return
        }

        guard !payload.sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            scannerError = "QR code is missing the session ID. Re-generate the code from the bridge."
            resetScanLock()
            return
        }

        let expiryDate = Date(timeIntervalSince1970: TimeInterval(payload.expiresAt) / 1000)
        if expiryDate.addingTimeInterval(codexSecureClockSkewToleranceSeconds) < Date() {
            scannerError = "This pairing QR code has expired. Generate a new one from the Mac bridge."
            resetScanLock()
            return
        }

        onScan(payload)
    }
}

// MARK: - Camera Preview UIViewRepresentable

private struct QRCameraPreview: UIViewRepresentable {
    let onScan: (String, _ resetScanLock: @escaping () -> Void) -> Void

    func makeUIView(context: Context) -> QRCameraUIView {
        let view = QRCameraUIView()
        view.onScan = { [weak view] code in
            onScan(code) {
                view?.resetScanLock()
            }
        }
        return view
    }

    func updateUIView(_ uiView: QRCameraUIView, context: Context) {}
}

private class QRCameraUIView: UIView, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?

    private let captureSession = AVCaptureSession()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let sessionQueue = DispatchQueue(label: "com.phodex.qr-camera")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false
    private var currentVideoOrientation: AVCaptureVideoOrientation = .portrait

    override init(frame: CGRect) {
        super.init(frame: frame)
        startObservingDeviceOrientation()
        setupCamera()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        startObservingDeviceOrientation()
        setupCamera()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
        updateCaptureOrientation()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateCaptureOrientation()
    }

    @objc
    private func handleDeviceOrientationDidChange() {
        updateCaptureOrientation()
    }

    private func startObservingDeviceOrientation() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }

    private func setupCamera() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return
        }

        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }

        if captureSession.canAddOutput(metadataOutput) {
            captureSession.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
            metadataOutput.metadataObjectTypes = [.qr]
        }

        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        self.layer.addSublayer(layer)
        previewLayer = layer
        updateCaptureOrientation()

        sessionQueue.async { [weak self] in
            self?.captureSession.startRunning()
        }
    }

    private func updateCaptureOrientation() {
        let orientation = captureVideoOrientation(for: UIDevice.current.orientation) ?? currentVideoOrientation

        if let connection = previewLayer?.connection,
           connection.isVideoOrientationSupported {
            connection.videoOrientation = orientation
        }

        if let connection = metadataOutput.connection(with: .video),
           connection.isVideoOrientationSupported {
            connection.videoOrientation = orientation
        }

        currentVideoOrientation = orientation
    }

    private func captureVideoOrientation(for deviceOrientation: UIDeviceOrientation) -> AVCaptureVideoOrientation? {
        switch deviceOrientation {
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        default:
            return nil
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasScanned,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let code = object.stringValue else {
            return
        }

        hasScanned = true
        HapticFeedback.shared.triggerImpactFeedback(style: .heavy)
        onScan?(code)
    }

    func resetScanLock() {
        hasScanned = false
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()

        let session = captureSession
        sessionQueue.async {
            session.stopRunning()
        }
    }
}
