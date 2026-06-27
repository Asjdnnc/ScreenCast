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

struct ContentView: View {
    @StateObject private var client = IPadClient()
    @State private var hostAddress: String = "192.168.1.10"
    @State private var showWiFiInput: Bool = false
    @State private var showMenu: Bool = false
    private let displayLayer = AVSampleBufferDisplayLayer()
    
    var body: some View {
        ZStack(alignment: .leading) {
            GeometryReader { geometry in
                VideoDisplayView(videoLayer: displayLayer)
                    .background(Color.black)
                    .edgesIgnoringSafeArea(.all)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { value in
                                let eventType: UInt8 = value.translation == .zero ? 1 : 3
                                sendTouch(at: value.location, in: geometry.size, type: eventType)
                            }
                            .onEnded { value in
                                sendTouch(at: value.location, in: geometry.size, type: 2)
                            }
                    )
            }
            .edgesIgnoringSafeArea(.all)
            
            if client.status == "Connected" {
                VStack {
                    Spacer()
                    HStack {
                        Button(action: {
                            withAnimation {
                                showMenu.toggle()
                            }
                        }) {
                            Image(systemName: "line.3.horizontal")
                                .font(.title)
                                .padding()
                                .background(Color.black.opacity(0.6))
                                .foregroundColor(.white)
                                .clipShape(Circle())
                        }
                        .padding()
                        Spacer()
                    }
                }
            }
            
            if client.status != "Connected" || showMenu {
                Color.black.opacity(0.4)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        if client.status == "Connected" {
                            withAnimation {
                                showMenu = false
                            }
                        }
                    }
                
                VStack(spacing: 20) {
                    Text("ScreenCast")
                        .font(.title)
                        .bold()
                    
                    Text("Status: \(client.status)")
                        .foregroundColor(.secondary)
                    
                    VStack(spacing: 12) {
                        Button(action: {
                            client.status = "Discovering USB..."
                            client.discoverAndConnect(preferUSB: true) { endpoint in
                                client.decoder = VideoDecoder(displayLayer: displayLayer)
                                client.connect(to: endpoint)
                                withAnimation { showMenu = false }
                            }
                        }) {
                            HStack {
                                Image(systemName: "cable.connector")
                                Text("Connect via USB Cable")
                                    .bold()
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                        
                        Button(action: {
                            withAnimation {
                                showWiFiInput.toggle()
                            }
                        }) {
                            HStack {
                                Image(systemName: "wifi")
                                Text("Connect via Wi-Fi")
                                    .bold()
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.secondary.opacity(0.15))
                            .foregroundColor(.primary)
                            .cornerRadius(10)
                        }
                        
                        if showWiFiInput {
                            HStack {
                                TextField("Mac Wi-Fi IP Address", text: $hostAddress)
                                    .keyboardType(.numbersAndPunctuation)
                                    .textFieldStyle(.roundedBorder)
                                    .autocapitalization(.none)
                                
                                Button(action: {
                                    client.decoder = VideoDecoder(displayLayer: displayLayer)
                                    let host = NWEndpoint.Host(hostAddress)
                                    let port = NWEndpoint.Port(rawValue: 12345)!
                                    client.connect(to: .hostPort(host: host, port: port))
                                    withAnimation { showMenu = false }
                                }) {
                                    Text("Connect")
                                        .bold()
                                }
                                .padding(.horizontal)
                            }
                            .padding(.top, 5)
                            .transition(.opacity)
                        }
                    }
                    
                    if client.status == "Connected" {
                        Button(action: {
                            client.disconnect()
                            withAnimation { showMenu = false }
                        }) {
                            HStack {
                                Image(systemName: "power")
                                Text("Disconnect")
                                    .bold()
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                        }
                    }
                }
                .padding()
                .frame(width: 320)
                .background(Color(UIColor.systemBackground))
                .cornerRadius(16)
                .shadow(radius: 10)
                .padding()
                .transition(.move(edge: .leading))
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
