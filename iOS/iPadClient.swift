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
    
    func connect(host: String, port: UInt16) {
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        
        connection = NWConnection(host: nwHost, port: nwPort, using: .tcp)
        connection?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
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
        connection?.cancel()
        connection = nil
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
                self?.receiveFrame(length: Int(length))
            } else if isComplete {
                self?.handleDisconnect()
            } else if error == nil {
                self?.receive()
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
                self?.handleDisconnect()
            } else if error == nil {
                self?.receive()
            }
        }
    }
    
    private func handleDisconnect() {
        DispatchQueue.main.async {
            self.status = "Disconnected"
            self.connection = nil
        }
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
    private let displayLayer = AVSampleBufferDisplayLayer()
    
    var body: some View {
        VStack(spacing: 20) {
            Text("iPad Display Client")
                .font(.title)
                .bold()
            
            Text("Status: \(client.status)")
                .foregroundColor(.secondary)
            
            HStack {
                TextField("Server IP", text: $hostAddress)
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                
                Button("Connect") {
                    client.decoder = VideoDecoder(displayLayer: displayLayer)
                    client.connect(host: hostAddress, port: 12345)
                }
                .disabled(client.status == "Connected")
                
                Button("Disconnect") {
                    client.disconnect()
                }
                .disabled(client.status != "Connected")
            }
            
            VideoDisplayView(videoLayer: displayLayer)
                .background(Color.black)
                .cornerRadius(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
    }
}
