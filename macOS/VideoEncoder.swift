import Foundation
import VideoToolbox
import CoreMedia

class VideoEncoder {
    private var session: VTCompressionSession?
    var onEncodedData: ((Data) -> Void)?
    
    func start(width: Int32, height: Int32) {
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { refcon, _, status, flags, sampleBuffer in
                guard status == noErr, let sampleBuffer = sampleBuffer else { return }
                let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon!).takeUnretainedValue()
                encoder.process(sampleBuffer: sampleBuffer)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        
        guard status == noErr, let session = session else { return }
        
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 30 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFNumber)
        
        VTCompressionSessionPrepareToEncodeFrames(session)
    }
    
    func encode(sampleBuffer: CMSampleBuffer) {
        guard let session = session, let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }
    
    func stop() {
        if let session = session {
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
    }
    
    private func process(sampleBuffer: CMSampleBuffer) {
        guard let data = getAnnexBData(from: sampleBuffer) else { return }
        onEncodedData?(data)
    }
    
    private func getAnnexBData(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        var data = Data()
        
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        var isKeyframe = true
        if let attachments = attachments, CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
            if CFDictionaryContainsKey(dict, unsafeBitCast(kCMSampleAttachmentKey_NotSync, to: UnsafeRawPointer.self)) {
                isKeyframe = false
            }
        }
        
        if isKeyframe {
            var parameterSetCount = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)
            for i in 0..<parameterSetCount {
                var parameterSetPointer: UnsafePointer<UInt8>?
                var parameterSetSize = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: i, parameterSetPointerOut: &parameterSetPointer, parameterSetSizeOut: &parameterSetSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let pointer = parameterSetPointer {
                    data.append(contentsOf: [0, 0, 0, 1])
                    data.append(pointer, count: parameterSetSize)
                }
            }
        }
        
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        
        if status == noErr, let pointer = dataPointer {
            var offset = 0
            while offset < totalLength - 4 {
                var nalUnitLength: UInt32 = 0
                memcpy(&nalUnitLength, pointer.advanced(by: offset), 4)
                nalUnitLength = CFSwapInt32BigToHost(nalUnitLength)
                data.append(contentsOf: [0, 0, 0, 1])
                data.append(UnsafePointer<UInt8>(OpaquePointer(pointer.advanced(by: offset + 4))), count: Int(nalUnitLength))
                offset += 4 + Int(nalUnitLength)
            }
        }
        
        return data
    }
}
