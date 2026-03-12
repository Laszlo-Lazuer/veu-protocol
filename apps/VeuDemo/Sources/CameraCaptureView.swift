import SwiftUI
import AVFoundation

/// Camera capture view for taking photos to encrypt as artifacts.
struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void

    func makeUIViewController(context: Context) -> CameraCaptureViewController {
        let vc = CameraCaptureViewController()
        vc.onCapture = onCapture
        return vc
    }

    func updateUIViewController(_ uiViewController: CameraCaptureViewController, context: Context) {}
}

final class CameraCaptureViewController: UIViewController {
    var onCapture: ((Data) -> Void)?
    private var captureSession: AVCaptureSession?
    private var photoOutput: AVCapturePhotoOutput?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var captureButton: UIButton?
    private var photoDelegate: PhotoDelegate?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        requestCameraPermission()
        setupCaptureButton()
    }

    private func requestCameraPermission() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    self?.setupCamera()
                } else {
                    self?.showFallback("Camera access denied.\nGo to Settings → Privacy → Camera to enable.")
                }
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        captureButton?.center = CGPoint(x: view.bounds.midX, y: view.bounds.maxY - 60)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let session = captureSession, !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession?.stopRunning()
    }

    private func setupCamera() {
        let session = AVCaptureSession()
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            showFallback("Camera unavailable")
            return
        }

        session.addInput(input)

        let output = AVCapturePhotoOutput()
        guard session.canAddOutput(output) else {
            showFallback("Photo capture unavailable")
            return
        }

        session.addOutput(output)
        photoOutput = output

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview

        // Ensure capture button stays above the preview layer
        if let button = captureButton {
            view.bringSubviewToFront(button)
        }

        captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    private func setupCaptureButton() {
        let button = UIButton(type: .system)
        button.frame = CGRect(x: 0, y: 0, width: 72, height: 72)
        button.backgroundColor = .white
        button.layer.cornerRadius = 36
        button.layer.borderWidth = 4
        button.layer.borderColor = UIColor.systemGreen.cgColor
        button.addTarget(self, action: #selector(capturePhoto), for: .touchUpInside)
        view.addSubview(button)
        captureButton = button
    }

    @objc private func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        let delegate = PhotoDelegate(onCapture: { [weak self] data in
            self?.onCapture?(data)
        })
        photoDelegate = delegate  // Retain delegate until callback fires
        photoOutput?.capturePhoto(with: settings, delegate: delegate)
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    private func showFallback(_ message: String) {
        let label = UILabel()
        label.text = message
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }
}

// MARK: - Photo capture delegate

private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    let onCapture: (Data) -> Void

    init(onCapture: @escaping (Data) -> Void) {
        self.onCapture = onCapture
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard let data = photo.fileDataRepresentation() else { return }
        DispatchQueue.main.async {
            self.onCapture(data)
        }
    }
}
