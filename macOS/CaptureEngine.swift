import SwiftUI
import ScreenCaptureKit
import Combine
import CoreMedia
import VideoToolbox
import Network

class VirtualDisplayManager {
    private var display: NSObject?
    var displayID: CGDirectDisplayID?
    
    func createDisplay() {
        print("🖥️ VDM: Starting virtual display creation...")
        guard let DescriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let ModeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type,
              let SettingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let DisplayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type else {
            print("🖥️ VDM: Failed to lookup private display classes!")
            return
        }
        
        let descriptor = DescriptorClass.init()
        descriptor.setValue("Screenshare Virtual Monitor", forKey: "name")
        descriptor.setValue(2048 as UInt32, forKey: "maxPixelsWide")
        descriptor.setValue(1536 as UInt32, forKey: "maxPixelsHigh")
        descriptor.setValue(CGSize(width: 400, height: 300), forKey: "sizeInMillimeters")
        descriptor.setValue(0x1234 as UInt32, forKey: "vendorID")
        descriptor.setValue(0x5678 as UInt32, forKey: "productID")
        descriptor.setValue(0x0001 as UInt32, forKey: "serialNum")
        descriptor.setValue(DispatchQueue(label: "com.aditya.screenshare.display"), forKey: "queue")
        
        let mode = ModeClass.init()
        mode.setValue(2048 as CGFloat, forKey: "width")
        mode.setValue(1536 as CGFloat, forKey: "height")
        mode.setValue(60.0 as Double, forKey: "refreshRate")
        
        let settings = SettingsClass.init()
        settings.setValue([mode], forKey: "modes")
        settings.setValue(1 as UInt32, forKey: "hiDPI")
        
        guard let allocated = DisplayClass.perform(Selector(("alloc")))?
            .takeUnretainedValue() as? NSObject else {
            print("🖥️ VDM: Alloc failed!")
            return
        }
        
        guard let initialized = allocated.perform(Selector(("initWithDescriptor:")), with: descriptor)?
            .takeRetainedValue() as? NSObject else {
            print("🖥️ VDM: Init with descriptor failed!")
            return
        }
        
        _ = initialized.perform(Selector(("applySettings:")), with: settings)
        
        self.display = initialized
        
        if let dID = initialized.value(forKey: "displayID") as? UInt32 {
            self.displayID = CGDirectDisplayID(dID)
            print("🖥️ VDM: Created display successfully with ID: \(dID)")
        } else {
            print("🖥️ VDM: displayID property was nil!")
        }
    }
    
    func destroyDisplay() {
        display = nil
        displayID = nil
    }
}

class MacServer: ObservableObject {
    private var listener: NWListener?
    @Published var connection: NWConnection?
    @Published var status: String = "Stopped"
    var onConnectionReady: (() -> Void)?
    
    let port: NWEndpoint.Port = 12345
    private var udpListener: NWListener?
    private var broadcastConnection: NWConnection?
    
    func start() {
        startUDPListener()
        do {
            listener = try NWListener(using: .tcp, on: port)
            listener?.service = NWListener.Service(name: "Mac Display Server", type: "_screenshare._tcp")
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
    
    private func startUDPListener() {
        do {
            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: 12346)
            self.broadcastConnection = nil
            
            listener.newConnectionHandler = { connection in
                connection.stateUpdateHandler = { state in
                    if case .ready = state {
                        connection.receiveMessage { data, _, _, _ in
                            if let data = data, let str = String(data: data, encoding: .utf8), str == "screenshare-client-request" {
                                let replyData = "screenshare-server-response".data(using: .utf8)!
                                connection.send(content: replyData, completion: .contentProcessed { _ in
                                    connection.cancel()
                                })
                            }
                        }
                    }
                }
                connection.start(queue: .main)
            }
            self.udpListener = listener
            listener.start(queue: .main)
        } catch {
            print("🖥️ MacServer: UDP Listener failed: \(error)")
        }
    }
    
    private func setupConnection(_ connection: NWConnection) {
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
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
                self?.connection = nil
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
    private let displayManager = VirtualDisplayManager()
    var server: MacServer?
    
    func startCapture() async {
        print("🖥️ CaptureEngine: startCapture() entered")
        guard CGPreflightScreenCaptureAccess() else {
            print("🖥️ CaptureEngine: Screen capture access not authorized")
            CGRequestScreenCaptureAccess()
            return
        }
        
        displayManager.createDisplay()
        guard let virtualDisplayID = displayManager.displayID else {
            print("🖥️ CaptureEngine: No displayID returned from displayManager")
            return
        }
        print("🖥️ CaptureEngine: Virtual display ID is \(virtualDisplayID). Querying SCShareableContent...")
        
        do {
            var display: SCDisplay? = nil
            for i in 0..<10 {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                display = content.displays.first(where: { $0.displayID == virtualDisplayID })
                if display != nil {
                    print("🖥️ CaptureEngine: Found virtual display on attempt \(i + 1)")
                    break
                }
                print("🖥️ CaptureEngine: Virtual display not found yet on attempt \(i + 1). Retrying...")
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            
            guard let activeDisplay = display else {
                print("🖥️ CaptureEngine: Virtual display not found in ScreenCaptureKit list after 10 retries")
                return
            }
            
            let filter = SCContentFilter(display: activeDisplay, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = 2048
            config.height = 1536
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.queueDepth = 5
            
            stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            
            encoder.start(width: 2048, height: 1536)
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
            displayManager.destroyDisplay()
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

func getLocalIPAddresses() -> [String] {
    var addresses = [String]()
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return [] }
    guard let firstAddr = ifaddr else { return [] }
    
    for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
        let flags = Int32(ptr.pointee.ifa_flags)
        var addr = ptr.pointee.ifa_addr.pointee
        
        if (flags & IFF_LOOPBACK) == 0 {
            if addr.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(&addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let address = String(cString: hostname)
                    addresses.append(address)
                }
            }
        }
    }
    freeifaddrs(ifaddr)
    return addresses
}

struct MirrorView: View {
    @StateObject private var server = MacServer()
    @StateObject private var engine = CaptureEngine()
    @State private var localIPs: [String] = []
    
    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Text("ScreenCast")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.linearGradient(colors: [.primary, .secondary], startPoint: .top, endPoint: .bottom))
                Text("VIRTUAL DISPLAY CONTROLLER")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .tracking(2)
            }
            
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(server.status)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(20)
            
            if !localIPs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("AVAILABLE INTERFACES")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                        .tracking(1)
                    
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(localIPs, id: \.self) { ip in
                            HStack {
                                Image(systemName: ip.hasPrefix("169.254") || ip.hasPrefix("172.20") ? "cable.connector" : "wifi")
                                    .foregroundColor(.blue)
                                    .font(.system(size: 12))
                                Text(ip)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(.primary)
                                Spacer()
                            }
                        }
                    }
                }
                .padding(14)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
                )
            }
            
            VStack(spacing: 12) {
                Text("VIRTUAL DISPLAY LIVE STREAM")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                    .tracking(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black)
                        .aspectRatio(4/3, contentMode: .fit)
                        .overlay(
                            Group {
                                if let image = engine.currentFrame {
                                    Image(image, scale: 1.0, label: Text("Virtual Screen Output"))
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .cornerRadius(8)
                                        .padding(4)
                                } else {
                                    VStack(spacing: 10) {
                                        Image(systemName: "display.trianglebadge.exclamationmark")
                                            .font(.system(size: 28))
                                            .foregroundColor(.secondary.opacity(0.5))
                                        Text("Waiting for connection...")
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        )
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                )
            }
        }
        .padding(24)
        .frame(width: 360, height: 480)
        .onAppear {
            localIPs = getLocalIPAddresses()
            engine.server = server
            server.onConnectionReady = {
                Task {
                    await engine.startCapture()
                }
            }
            server.onConnectionClosed = {
                Task {
                    await engine.stopCapture()
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
    
    private var statusColor: Color {
        if server.status == "Connected" {
            return .green
        } else if server.status.contains("Listening") {
            return .blue
        } else {
            return .red
        }
    }
}
