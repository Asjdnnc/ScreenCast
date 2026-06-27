import Foundation
import Network
import SwiftUI
import Combine
import AVFoundation
import VideoToolbox

class VideoDecoder {
    private var formatDescription: CMVideoFormatDescription?
    let displayLayer: AVSampleBufferDisplayLayer
    
    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
    }
    
    func decode(frameData: Data) {
        var sps: [UInt8]?
        var pps: [UInt8]?
        var naluOffsets: [Int] = []
        
        var i = 0
        while i < frameData.count - 4 {
            if frameData[i] == 0 && frameData[i+1] == 0 && frameData[i+2] == 0 && frameData[i+3] == 1 {
                naluOffsets.append(i)
                i += 4
            } else if frameData[i] == 0 && frameData[i+1] == 0 && frameData[i+2] == 1 {
                naluOffsets.append(i)
                i += 3
            } else {
                i += 1
            }
        }
        
        var bodyData = Data()
        
        for index in 0..<naluOffsets.count {
            let start = naluOffsets[index]
            let end = (index + 1 < naluOffsets.count) ? naluOffsets[index + 1] : frameData.count
            
            let startCodeLength = (frameData[start + 2] == 1) ? 3 : 4
            let naluData = frameData.subdata(in: (start + startCodeLength)..<end)
            guard !naluData.isEmpty else { continue }
            
            let naluType = naluData[0] & 0x1F
            
            if naluType == 7 {
                sps = [UInt8](naluData)
            } else if naluType == 8 {
                pps = [UInt8](naluData)
            } else {
                var length = UInt32(naluData.count).bigEndian
                bodyData.append(Data(bytes: &length, count: 4))
                bodyData.append(naluData)
            }
        }
        
        if let sps = sps, let pps = pps {
            let spsPointer = UnsafePointer<UInt8>(sps)
            let ppsPointer = UnsafePointer<UInt8>(pps)
            
            var parameterSetPointers = [spsPointer, ppsPointer]
            var parameterSetSizes = [sps.count, pps.count]
            
            let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: 2,
                parameterSetPointers: &parameterSetPointers,
                parameterSetSizes: &parameterSetSizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &formatDescription
            )
            
            if status != noErr {
                print("Failed to create format description: \(status)")
                return
            }
        }
        
        guard let formatDescription = formatDescription, !bodyData.isEmpty else { return }
        
        var blockBuffer: CMBlockBuffer?
        let totalSize = bodyData.count
        
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        
        guard status == noErr, let buffer = blockBuffer else {
            print("Failed to create block buffer: \(status)")
            return
        }
        
        bodyData.withUnsafeBytes { rawBufferPointer in
            if let baseAddress = rawBufferPointer.baseAddress {
                CMBlockBufferReplaceDataBytes(
                    with: baseAddress,
                    blockBuffer: buffer,
                    offsetIntoDestination: 0,
                    dataLength: totalSize
                )
            }
        }
        
        var sampleBuffer: CMSampleBuffer?
        var sampleSizeArray = [totalSize]
        
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizeArray,
            sampleBufferOut: &sampleBuffer
        )
        
        guard status == noErr, let sb = sampleBuffer else {
            print("Failed to create sample buffer: \(status)")
            return
        }
        
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sb)
        } else {
            print("Display layer not ready for more media data")
        }
    }
}

class IPadClient: ObservableObject {
    private var connection: NWConnection?
    @Published var status: String = "Disconnected"
    var decoder: VideoDecoder?
    
    func connect(to endpoint: NWEndpoint) {
        print("📱 Client connecting to \(endpoint)...")
        connection = NWConnection(to: endpoint, using: .tcp)
        connection?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                print("📱 Client connection state changed to: \(state)")
                switch state {
                case .ready:
                    self?.status = "Connected"
                    self?.receive()
                case .failed(let error):
                    self?.status = "Failed: \(error.localizedDescription)"
                case .cancelled:
                    self?.status = "Disconnected"
                default:
                    break
                }
            }
        }
        connection?.start(queue: .main)
    }
    
    func disconnect() {
        print("📱 Client disconnecting...")
        connection?.cancel()
        connection = nil
    }
    
    func send(data: Data) {
        guard let connection = connection else { return }
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("📱 Client send error: \(error)")
            }
        })
    }
    
    private func receive() {
        guard let connection = connection else { return }
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            if let data = data, data.count == 4 {
                let length = data.withUnsafeBytes { buffer -> UInt32 in
                    let bytes = buffer.bindMemory(to: UInt8.self)
                    return (UInt32(bytes[0]) << 24) |
                           (UInt32(bytes[1]) << 16) |
                           (UInt32(bytes[2]) << 8)  |
                           UInt32(bytes[3])
                }
                print("📱 Client expecting frame of length: \(length)")
                self?.receiveFrame(length: Int(length))
            } else if isComplete {
                print("📱 Client connection closed by server (EOF)")
                self?.handleDisconnect()
            } else if let error = error {
                print("📱 Client header read error: \(error)")
            }
        }
    }
    
    private func receiveFrame(length: Int) {
        guard let connection = connection else { return }
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            if let data = data, data.count == length {
                self?.decoder?.decode(frameData: data)
                self?.receive()
            } else if isComplete {
                print("📱 Client connection closed by server (EOF) during frame read")
                self?.handleDisconnect()
            } else if let error = error {
                print("📱 Client frame read error: \(error)")
            }
        }
    }
    
    private func handleDisconnect() {
        DispatchQueue.main.async {
            self.status = "Disconnected"
            self.connection = nil
        }
    }
    
    private var browser: NWBrowser?
    
    func discoverAndConnect(preferUSB: Bool, completion: @escaping (NWEndpoint) -> Void) {
        let parameters = NWParameters()
        let browser = NWBrowser(for: .bonjour(type: "_screenshare._tcp", domain: nil), using: parameters)
        self.browser = browser
        
        browser.browseResultsChangedHandler = { results, changes in
            if let firstResult = results.first {
                DispatchQueue.main.async {
                    completion(firstResult.endpoint)
                }
                browser.cancel()
            }
        }
        browser.start(queue: .main)
    }
}

class AVSampleBufferDisplayUIView: UIView {
    private let videoLayer: AVSampleBufferDisplayLayer
    
    init(videoLayer: AVSampleBufferDisplayLayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)
        videoLayer.videoGravity = .resizeAspect
        layer.addSublayer(videoLayer)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        videoLayer.frame = bounds
    }
}

struct VideoDisplayView: UIViewRepresentable {
    let videoLayer: AVSampleBufferDisplayLayer
    
    func makeUIView(context: Context) -> AVSampleBufferDisplayUIView {
        return AVSampleBufferDisplayUIView(videoLayer: videoLayer)
    }
    
    func updateUIView(_ uiView: AVSampleBufferDisplayUIView, context: Context) {}
}

struct BlurView: UIViewRepresentable {
    let style: UIBlurEffect.Style
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}

struct MonitorLogoView: View {
    var size: CGFloat = 80
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.15, style: .continuous)
                .stroke(
                    LinearGradient(colors: [Color.blue, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: size * 0.06
                )
                .frame(width: size, height: size * 0.72)
                .shadow(color: Color.blue.opacity(0.3), radius: 5, x: 0, y: 3)
            
            VStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(LinearGradient(colors: [Color.blue, Color.purple], startPoint: .leading, endPoint: .trailing))
                    .frame(width: size * 0.12, height: size * 0.18)
                RoundedRectangle(cornerRadius: size * 0.03, style: .continuous)
                    .fill(LinearGradient(colors: [Color.blue, Color.purple], startPoint: .leading, endPoint: .trailing))
                    .frame(width: size * 0.36, height: size * 0.06)
            }
            .frame(width: size, height: size * 0.92)
            
            Text("S")
                .font(.system(size: size * 0.42, weight: .black, design: .rounded))
                .foregroundStyle(
                    LinearGradient(colors: [Color.blue, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .offset(y: -size * 0.04)
        }
        .frame(width: size, height: size)
    }
}

struct CastingPulseView: View {
    @State private var scale: CGFloat = 1.0
    @State private var opacity: Double = 0.5
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(LinearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom), lineWidth: 2)
                .scaleEffect(scale)
                .opacity(opacity)
                .frame(width: 160, height: 160)
                .onAppear {
                    withAnimation(.easeOut(duration: 2.0).repeatForever(autoreverses: false)) {
                        scale = 2.0
                        opacity = 0.0
                    }
                }
            
            Circle()
                .stroke(LinearGradient(colors: [.purple, .blue], startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
                .scaleEffect(scale - 0.3)
                .opacity(opacity)
                .frame(width: 160, height: 160)
                .onAppear {
                    withAnimation(.easeOut(duration: 2.0).delay(0.6).repeatForever(autoreverses: false)) {
                        scale = 2.0
                        opacity = 0.0
                    }
                }
        }
    }
}

struct InfoSheet: View {
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack {
                    Spacer()
                    Button(action: {
                        dismiss()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                
                Image("AppLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
                    .cornerRadius(16)
                    .shadow(radius: 4)
                
                Text("ScreenCast")
                    .font(.title2)
                    .bold()
                
                Text("Developer: Aditya Kumar")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Divider()
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("System Architecture")
                        .font(.headline)
                        .padding(.bottom, 4)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        bulletPoint(title: "Transport Layer", desc: "Low-latency Apple Network framework sockets optimized for Lightning USB wired connections.")
                        bulletPoint(title: "Display Engine", desc: "Virtual display creation via macOS 14+ CGVirtualDisplay API matching iPad native dimensions.")
                        bulletPoint(title: "Video Pipeline", desc: "Real-time frame capture using ScreenCaptureKit linked directly to a VideoToolbox H.264 hardware encoding session.")
                        bulletPoint(title: "Receiver & Render", desc: "Client-side H.264 hardware decoding via VideoToolbox, rendered fluently using AVSampleBufferDisplayLayer.")
                        bulletPoint(title: "Input Loop", desc: "Multi-touch gesture processing mapping normalized iPad coordinates back to macOS CoreGraphics system mouse events.")
                    }
                }
                
                Divider()
                
                Link(destination: URL(string: "https://github.com/Asjdnnc/ScreenCast")!) {
                    HStack {
                        Image(systemName: "link")
                        Text("GitHub Repository")
                            .bold()
                    }
                    .foregroundColor(.blue)
                }
                .padding(.top, 8)
            }
            .padding(24)
        }
        .frame(maxWidth: 420)
    }
    
    private func bulletPoint(title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
                .bold()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                Text(desc)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var client = IPadClient()
    @State private var hostAddress: String = "192.168.1.10"
    @State private var showWiFiInput: Bool = false
    @State private var isPencilMode: Bool = false
    @State private var showControlBar: Bool = true
    @State private var keyboardInput: String = " "
    @FocusState private var isKeyboardFocused: Bool
    @State private var logoScale: CGFloat = 1.0
    @State private var showInfo = false
    
    @State private var autoHideTimer: Timer?
    private let displayLayer = AVSampleBufferDisplayLayer()
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            GeometryReader { geometry in
                VideoDisplayView(videoLayer: displayLayer)
                    .background(Color.black)
                    .edgesIgnoringSafeArea(.all)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { value in
                                triggerActivity()
                                if !isPencilMode {
                                    if value.translation == .zero {
                                        sendTouch(at: value.location, in: geometry.size, type: 1)
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                            sendTouch(at: value.location, in: geometry.size, type: 2)
                                        }
                                    } else {
                                        sendTouch(at: value.location, in: geometry.size, type: 0)
                                    }
                                } else {
                                    let eventType: UInt8 = value.translation == .zero ? 1 : 3
                                    sendTouch(at: value.location, in: geometry.size, type: eventType)
                                }
                            }
                            .onEnded { value in
                                triggerActivity()
                                if isPencilMode {
                                    sendTouch(at: value.location, in: geometry.size, type: 2)
                                }
                            }
                    )
                    .onTapGesture {
                        triggerActivity()
                    }
            }
            .edgesIgnoringSafeArea(.all)
            
            TextField("", text: $keyboardInput)
                .focused($isKeyboardFocused)
                .opacity(0)
                .frame(width: 1, height: 1)
                .keyboardType(.default)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .onChange(of: keyboardInput) { newValue in
                    if newValue.isEmpty {
                        var chars: UInt16 = 0x007F
                        var packet = Data()
                        packet.append(11)
                        packet.append(Data(bytes: &chars, count: 2))
                        packet.append(Data(repeating: 0, count: 6))
                        client.send(data: packet)
                    } else if newValue.count > 1 {
                        if let char = newValue.last {
                            let utf16Val = char.utf16.first!
                            var packet = Data()
                            packet.append(11)
                            var val = utf16Val
                            packet.append(Data(bytes: &val, count: 2))
                            packet.append(Data(repeating: 0, count: 6))
                            client.send(data: packet)
                        }
                    }
                    keyboardInput = " "
                }
            
            if client.status != "Connected" {
                LinearGradient(colors: [Color(white: 0.08), Color(white: 0.03)], startPoint: .top, endPoint: .bottom)
                    .edgesIgnoringSafeArea(.all)
                
                VStack(spacing: 30) {
                    Spacer()
                    
                    VStack(spacing: 12) {
                        Image("AppLogo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 90, height: 90)
                            .cornerRadius(18)
                            .shadow(color: Color.blue.opacity(0.3), radius: 8, x: 0, y: 4)
                            .scaleEffect(logoScale)
                            .onAppear {
                                withAnimation(.spring(response: 0.6, dampingFraction: 0.6).repeatForever(autoreverses: true)) {
                                    logoScale = 1.05
                                }
                            }
                        
                        Text("ScreenCast")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(.linearGradient(colors: [.white, .white.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                        
                        Text("VIRTUAL DISPLAY CONTROLLER")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.blue)
                            .tracking(3)
                    }
                    
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(client.status.contains("Discovering") ? Color.orange : Color.blue)
                                .frame(width: 6, height: 6)
                            Text(client.status)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity.opacity(0.04))
                        .cornerRadius(20)
                    }
                    
                    Spacer()
                    
                    VStack(spacing: 16) {
                        Button(action: {
                            client.status = "Discovering USB..."
                            client.discoverAndConnect(preferUSB: true) { endpoint in
                                client.decoder = VideoDecoder(displayLayer: displayLayer)
                                client.connect(to: endpoint)
                                triggerActivity()
                            }
                        }) {
                            HStack(spacing: 10) {
                                Image(systemName: "cable.connector")
                                Text("Connect via USB Cable")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
                            .foregroundColor(.white)
                            .cornerRadius(14)
                            .shadow(color: Color.blue.opacity(0.3), radius: 10, y: 5)
                        }
                        
                        Button(action: {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                showWiFiInput.toggle()
                            }
                        }) {
                            HStack(spacing: 10) {
                                Image(systemName: "wifi")
                                Text("Connect via Wi-Fi")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.white.opacity(0.05))
                            .foregroundColor(.white)
                            .cornerRadius(14)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                            )
                        }
                        
                        if showWiFiInput {
                            VStack(spacing: 12) {
                                HStack {
                                    TextField("Mac IP Address", text: $hostAddress)
                                        .keyboardType(.numbersAndPunctuation)
                                        .textFieldStyle(.plain)
                                        .padding()
                                        .background(Color.white.opacity(0.04))
                                        .cornerRadius(10)
                                        .foregroundColor(.white)
                                        .autocapitalization(.none)
                                    
                                    Button(action: {
                                        client.decoder = VideoDecoder(displayLayer: displayLayer)
                                        let host = NWEndpoint.Host(hostAddress)
                                        let port = NWEndpoint.Port(rawValue: 12345)!
                                        client.connect(to: .hostPort(host: host, port: port))
                                        triggerActivity()
                                    }) {
                                        Text("Connect")
                                            .font(.system(size: 15, weight: .bold))
                                            .padding(.horizontal, 20)
                                            .padding(.vertical, 12)
                                            .background(Color.blue)
                                            .foregroundColor(.white)
                                            .cornerRadius(10)
                                    }
                                }
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .frame(maxWidth: 340)
                    .padding(.bottom, 50)
                }
                .padding()
            }
            
            if client.status == "Connected" {
                VStack {
                    Spacer()
                    if showControlBar {
                        HStack(spacing: 24) {
                            Button(action: {
                                isPencilMode = false
                                triggerActivity()
                            }) {
                                VStack(spacing: 4) {
                                    Image(systemName: "hand.tap")
                                        .font(.title3)
                                    Text("Mouse")
                                        .font(.system(size: 9, weight: .bold))
                                }
                                .foregroundColor(!isPencilMode ? .blue : .white.opacity(0.6))
                            }
                            
                            Button(action: {
                                isPencilMode = true
                                triggerActivity()
                            }) {
                                VStack(spacing: 4) {
                                    Image(systemName: "pencil")
                                        .font(.title3)
                                    Text("Pencil")
                                        .font(.system(size: 9, weight: .bold))
                                }
                                .foregroundColor(isPencilMode ? .blue : .white.opacity(0.6))
                            }
                            
                            Button(action: {
                                isKeyboardFocused.toggle()
                                triggerActivity()
                            }) {
                                VStack(spacing: 4) {
                                    Image(systemName: "keyboard")
                                        .font(.title3)
                                    Text("Keyboard")
                                        .font(.system(size: 9, weight: .bold))
                                }
                                .foregroundColor(isKeyboardFocused ? .blue : .white.opacity(0.6))
                            }
                            
                            Divider()
                                .frame(height: 30)
                                .background(Color.white.opacity(0.2))
                            
                            Button(action: {
                                client.disconnect()
                            }) {
                                VStack(spacing: 4) {
                                    Image(systemName: "power")
                                        .font(.title3)
                                    Text("Disconnect")
                                        .font(.system(size: 9, weight: .bold))
                                }
                                .foregroundColor(.red)
                            }
                        }
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(Color.black.opacity(0.65))
                        .background(BlurView(style: .systemUltraThinMaterialDark))
                        .cornerRadius(28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 28)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.4), radius: 15, y: 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 24)
                    } else {
                        Button(action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                showControlBar = true
                            }
                            triggerActivity()
                        }) {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 16, weight: .bold))
                                .padding(.horizontal, 24)
                                .padding(.vertical, 8)
                                .background(Color.black.opacity(0.5))
                                .background(BlurView(style: .systemUltraThinMaterialDark))
                                .foregroundColor(.white.opacity(0.8))
                                .cornerRadius(16)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )
                        }
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            
            if client.status != "Connected" {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(action: {
                            showInfo = true
                        }) {
                            Image(systemName: "info.circle")
                                .font(.title2)
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .padding(24)
                    }
                }
            }
        }
        .sheet(isPresented: $showInfo) {
            InfoSheet()
        }
    }
    
    private func triggerActivity() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            showControlBar = true
        }
        autoHideTimer?.invalidate()
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { _ in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                showControlBar = false
            }
        }
    }
    
    private func sendTouch(at point: CGPoint, in size: CGSize, type: UInt8) {
        guard size.width > 0, size.height > 0 else { return }
        let normX = Float(point.x / size.width)
        let normY = Float(point.y / size.height)
        
        var packet = Data()
        packet.append(type)
        
        var x = normX
        var y = normY
        packet.append(Data(bytes: &x, count: 4))
        packet.append(Data(bytes: &y, count: 4))
        
        client.send(data: packet)
    }
}
