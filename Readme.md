# iPad as a Mac Display: Build Plan

## Phase 1: The "Hello World" Connection (Transport Layer)

**Goal:** Establish a reliable, low-latency connection between your MacBook and your iPad. Before sending video, prove the devices can talk to each other.

**Deliverables:**
- A basic macOS app and a basic iOS app.
- A network socket using Apple’s Network framework (for Wi-Fi) or a library like Peertalk (for Lightning cable via usbmuxd).
- The ability to send a simple text string, such as "Ping," from the Mac and have it print on the iPad screen, and vice versa.

## Phase 2: Frame Capture (macOS Mirroring)

**Goal:** Capture what is currently on your Mac screen. Instead of creating a second screen right away, start by simply mirroring your primary Mac screen.

**Deliverables:**
- Implement ScreenCaptureKit in your macOS app.
- Continuously capture raw frames from your main display.
- Display those raw frames within a small window on your Mac just to verify the capture loop is working efficiently.

## Phase 3: The Video Pipeline (Encoding & Transmitting)

**Goal:** Compress the captured frames and send them over the Phase 1 connection. Raw frames are too massive to send over Wi-Fi or USB without lagging.

**Deliverables:**
- Use the VideoToolbox framework on macOS to hardware-encode the raw frames into an H.264 video stream.
- Packetize this video stream and send it over your established network socket to the iPad.

## Phase 4: The Receiver (iOS Rendering)

**Goal:** Receive the video stream on the iPad and paint it to the screen.

**Deliverables:**
- Use VideoToolbox on the iPad to decode the incoming H.264 packets back into frames.
- Use AVSampleBufferDisplayLayer, or Metal if you want maximum performance control, to render those frames onto the iPad’s display with as little latency as possible.

**Milestone:** At this point, you have successfully built a screen-mirroring app.

## Phase 5: The Input Loop (Touch & Mouse Control)

**Goal:** Make the iPad interactive. If you tap the iPad screen, it should click the Mac.

**Deliverables:**
- Capture UITouch events, including taps and drags, on the iPad.
- Translate the iPad screen coordinates to map to the Mac’s screen coordinates.
- Send these coordinate packets back to the Mac.
- Use CoreGraphics (CGEvent) on the Mac to intercept those coordinates and simulate physical mouse movements and clicks.

## Phase 6: The Virtual Display (The Final Boss)

**Goal:** Trick macOS into extending the desktop rather than just mirroring it.

**Deliverables:**
- Replace your ScreenCaptureKit mirroring logic with Apple’s Virtual Display APIs, available in macOS 14 and later.
- Instantiate a fake monitor with the exact resolution of your iPad Air 2, 2048 × 1536.
- Route the output of this virtual monitor into your Phase 3 video pipeline.