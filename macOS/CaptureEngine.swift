import SwiftUI
import ScreenCaptureKit
import Combine
import CoreMedia
import VideoToolbox
import Network

class MacServer: ObservableObject {
    private var listener: NWListener?
    @Published var connection: NWConnection?
    @Published var status: String = "Stopped"
    var onConnectionReady: (() -> Void)?
    
    let port: NWEndpoint.Port = 12345
    
    func start() {
        do {
            listener = try NWListener(using: .tcp, on: port)
            listener?.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.status = "Listening on port \(self?.port.rawValue ?? 0)"
                    case .failed(let error):
                        self?.status = "Failed: \(error.localizedDescription)"
                    default:
                        break
                    }
                }
            }
            
            listener?.newConnectionHandler = { [weak self] newConnection in
                self?.setupConnection(newConnection)
            }
            
            listener?.start(queue: .main)
        } catch {
            status = "Start failed: \(error.localizedDescription)"
        }
    }
    
    private func setupConnection(_ connection: NWConnection) {
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                print("🖥️ Server connection state: \(state)")
                switch state {
                case .ready:
                    self?.status = "Connected"
                    self?.onConnectionReady?()
                    self?.receive()
                case .failed(let error):
                    self?.status = "Connection failed: \(error.localizedDescription)"
                    self?.connection = nil
                case .cancelled:
                    self?.status = "Connection cancelled"
                    self?.connection = nil
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }
    
    private func receive() {
        guard let connection = connection else { return }
        connection.receive(minimumIncompleteLength: 9, maximumLength: 9) { [weak self] data, _, isComplete, error in
            if let data = data, data.count == 9 {
                self?.handleInputPacket(data)
                self?.receive()
            } else if isComplete {
                print("🖥️ Server connection closed by client")
            } else if error == nil {
                self?.receive()
            }
        }
    }
    
    private func handleInputPacket(_ data: Data) {
        let type = data[0]
        let xBytes = data.subdata(in: 1..<5)
        let yBytes = data.subdata(in: 5..<9)
        
        let xNorm = xBytes.withUnsafeBytes { $0.load(as: Float.self) }
        let yNorm = yBytes.withUnsafeBytes { $0.load(as: Float.self) }
        
        guard let mainDisplay = NSScreen.main else { return }
        let screenFrame = mainDisplay.frame
        let targetX = CGFloat(xNorm) * screenFrame.width
        let targetY = CGFloat(yNorm) * screenFrame.height
        let point = CGPoint(x: targetX, y: targetY)
        
        let source = CGEventSource(stateID: .combinedSessionState)
        
        switch type {
        case 0:
            let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
            event?.post(tap: .cghidEventTap)
        case 1:
            let event = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
            event?.post(tap: .cghidEventTap)
        case 2:
            let event = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
            event?.post(tap: .cghidEventTap)
        case 3:
            let event = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)
            event?.post(tap: .cghidEventTap)
        default:
            break
        }
    }
    
    func send(data: Data) {
        guard let connection = connection else { return }
        var length = UInt32(data.count).bigEndian
        let packet = Data(bytes: &length, count: 4) + data
        connection.send(content: packet, completion: .contentProcessed { _ in })
    }
}

class CaptureEngine: NSObject, ObservableObject, SCStreamOutput {
    @Published var currentFrame: CGImage?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "video-capture-queue")
    private let encoder = VideoEncoder()
    var server: MacServer?
    
    func startCapture() async {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return }
            
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(display.width)
            config.height = Int(display.height)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.queueDepth = 5
            
            stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            
            encoder.start(width: Int32(display.width), height: Int32(display.height))
            encoder.onEncodedData = { [weak self] data in
                self?.server?.send(data: data)
            }
            
            try await stream?.startCapture()
        } catch {
            print(error)
        }
    }
    
    func stopCapture() async {
        do {
            try await stream?.stopCapture()
            stream = nil
            encoder.stop()
        } catch {
            print(error)
        }
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        encoder.encode(sampleBuffer: sampleBuffer)
        
        guard let imageBuffer = sampleBuffer.imageBuffer else { return }
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(imageBuffer, options: nil, imageOut: &cgImage)
        if let image = cgImage {
            DispatchQueue.main.async {
                self.currentFrame = image
            }
        }
    }
}

struct MirrorView: View {
    @StateObject private var server = MacServer()
    @StateObject private var engine = CaptureEngine()
    
    var body: some View {
        VStack(spacing: 20) {
            Text("macOS Display Server")
                .font(.title)
                .bold()
            
            Text("Status: \(server.status)")
                .foregroundColor(.secondary)
            
            if let image = engine.currentFrame {
                Image(image, scale: 1.0, label: Text("Screen Preview"))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 200)
                    .cornerRadius(8)
            } else {
                Text("Capture inactive")
                    .frame(height: 200)
            }
        }
        .padding()
        .frame(width: 400, height: 350)
        .onAppear {
            engine.server = server
            server.onConnectionReady = {
                Task {
                    await engine.startCapture()
                }
            }
            server.start()
        }
        .onDisappear {
            Task {
                await engine.stopCapture()
            }
        }
    }
}
