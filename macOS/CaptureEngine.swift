import SwiftUI
import ScreenCaptureKit
import Combine
import CoreMedia
import VideoToolbox

class CaptureEngine: NSObject, ObservableObject, SCStreamOutput {
    @Published var currentFrame: CGImage?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "video-capture-queue")
    private let encoder = VideoEncoder()
    
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
            encoder.onEncodedData = { data in
                print("🎥 H.264 Frame Encoded! Size: \(data.count) bytes")
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
    @StateObject private var engine = CaptureEngine()
    
    var body: some View {
        VStack {
            if let image = engine.currentFrame {
                Image(image, scale: 1.0, label: Text("Screen Mirror"))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Text("Waiting for stream...")
                    .foregroundColor(.secondary)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .onAppear {
            Task {
                await engine.startCapture()
            }
        }
        .onDisappear {
            Task {
                await engine.stopCapture()
            }
        }
    }
}
