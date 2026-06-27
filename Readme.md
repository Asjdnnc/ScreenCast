# ScreenCast

ScreenCast turns your iPad (specifically optimized for iPad Air 2) into a sleek, high-performance, and low-latency extended display for your Mac. By combining macOS's native virtual display APIs, hardware H.264 compression, and touch input mapping, ScreenCast provides a professional external display experience over both Lightning USB and Wi-Fi connections.

---

## Key Features

*   **Virtual Display Engine**: Dynamically registers a hardware-accelerated virtual monitor matching the iPad’s native resolution (2048 × 1536) using macOS 14+ `CGVirtualDisplay` APIs.
*   **Video Capture & Encoder Pipeline**: Real-time screen capture via Apple's high-performance `ScreenCaptureKit` framework, hardware-compressed to H.264 with low-latency using `VideoToolbox`.
*   **Receiver & Decoupled Render**: Client-side H.264 decoding on iPad using hardware-accelerated `VideoToolbox`, rendered fluently onto `AVSampleBufferDisplayLayer` with sub-frame presentation latency.
*   **Lightning USB & Wi-Fi Sockets**: High-speed communication channel built using the modern Apple `Network` framework. Automatically detects Lightning cable interfaces (`169.254.x.x` or `172.20.x.x`) via local link connections.
*   **Intuitive Input Modes**:
    *   **Mouse Mode**: Touch the screen to move the cursor to that window and click immediately. Slide your finger to hover and navigate the macOS workspace without drawing.
    *   **Pencil Mode**: Direct touch coordinate mapping designed for drawing, handwriting, and click-and-drag interactions.
*   **Minimalist Interface & Brand Layout**: Sleek dark mode design containing smooth launch animations, a floating/auto-hiding overlay control bar (keyboard, mode selector, disconnect button), and an embedded System Architecture inspector sheet.

---

## System Architecture

```
+-------------------------------------------------------------+
|                          MAC SERVER                         |
|                                                             |
|   +-----------------------+     +-----------------------+   |
|   |   CGVirtualDisplay    | --> |   ScreenCaptureKit    |   |
|   |   (2048x1536 screen)  |     |   (Frame Collector)   |   |
|   +-----------------------+     +-----------------------+   |
|                                             |               |
|                                             v               |
|   +-----------------------+     +-----------------------+   |
|   |     CGEvent Parser    |     |     VideoToolbox      |   |
|   |  (Mouse/Keyboard Sim) |     |    (H.264 Encoder)    |   |
|   +-----------------------+     +-----------------------+   |
|               ^                             |               |
+---------------+-----------------------------+---------------+
                | (TCP/UDP Input Events)      | (H.264 Packets over TCP)
                |                             v
+---------------+-----------------------------+---------------+
|               |          IPAD CLIENT        |               |
|                                                             |
|   +-----------------------+     +-----------------------+   |
|   |      Touch Loop       |     |     VideoToolbox      |   |
|   |  (Pencil/Mouse Mode)  |     |    (H.264 Decoder)    |   |
|   +-----------------------+     +-----------------------+   |
|                                             |               |
|                                             v               |
|                                 +-----------------------+   |
|                                 |     Display Layer     |   |
|                                 | (AVSampleBufferLayer) |   |
|                                 +-----------------------+   |
+-------------------------------------------------------------+
```

---

## Installation & Deployment Guide

Since the macOS application is provided as a precompiled release asset and the iOS application is installed using a free developer certificate, follow the steps below to set up both devices.

### macOS Server Application (Mac)

You can download and run the precompiled `ScreenCast.app` directly on your Mac without compiling the source code:

1.  Download the latest `ScreenCast.app` zip package from the GitHub releases section.
2.  Unzip the package to retrieve the standalone `ScreenCast.app` bundle.
3.  Drag and drop `ScreenCast.app` into your Mac's `/Applications` directory.
4.  **Bypass Gatekeeper**:
    *   Because the app is signed with a personal developer certificate, double-clicking it normally may trigger a warning from macOS.
    *   To open it, **right-click** `ScreenCast.app` in the Applications folder and choose **Open**.
    *   Click **Open** on the warning dialog to confirm. Alternatively, you can go to **System Settings -> Privacy & Security** and click **Open Anyway** under the security section.

---

### iOS Client Application (iPad)

Apple restricts running third-party unsigned applications on iOS devices without building them directly from source on a registered developer device. Follow these steps to sideload the app on your iPad:

1.  Connect your iPad to your Mac via a USB or Lightning cable.
2.  Open `Screenshare-ios.xcodeproj` in Xcode on your Mac.
3.  **Enable Developer Mode on your iPad**:
    *   On your iPad, go to **Settings -> Privacy & Security**.
    *   Scroll down to the Developer section and select **Developer Mode**.
    *   Toggle Developer Mode **On** and restart the iPad as prompted by the device.
    *   Once restarted, click **Turn On** and enter your passcode.
4.  In Xcode, select the **Screenshare-ios** target and select your physical iPad from the device destination list.
5.  Go to the target's **Signing & Capabilities** tab and select your **Personal Team** from the Team dropdown. (Xcode will automatically handle generating free developer provisioning profiles).
6.  Click the **Run** button (Play icon) in the top-left corner of Xcode.
7.  Xcode will build the binary, transfer it, and install it on your iPad.
8.  **Trust the Developer Certificate**:
    *   Before opening the application for the first time, your iPad will show an "Untrusted Developer" dialog.
    *   On your iPad, go to **Settings -> General -> VPN & Device Management**.
    *   Select your Apple ID developer profile listing under "Developer App".
    *   Tap **Trust "[Your Email Address]"** and confirm.
9.  Launch the **ScreenCast** app from the iPad Home Screen.

---

## Connecting Devices

### USB Lightning Connection (Recommended for Low Latency)

1.  Connect your iPad to your Mac using the USB-to-Lightning cable.
2.  Launch the **ScreenCast** server app on your Mac.
3.  Locate the automatically assigned cable interface address (it typically starts with `169.254.x.x` or `172.20.x.x`) shown under **Available Interfaces**.
4.  Launch the **ScreenCast** client app on your iPad.
5.  Tap the **Connect via USB Cable** button. The app will automatically resolve the local interface connection and start rendering your extended virtual desktop screen.

### Wi-Fi Connection

1.  Ensure both your Mac and iPad are connected to the same local Wi-Fi network.
2.  Launch **ScreenCast** on your Mac.
3.  Launch **ScreenCast** on your iPad.
4.  Tap **Connect via Wi-Fi**.
5.  Enter the active Mac IP address shown on the Mac application interface and click **Connect**.