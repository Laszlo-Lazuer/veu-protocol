# veu-app: The Double Mirror UX

The Veu mobile application is the physical lens for the protocol. It is designed around a single, central interaction: **The Vue/Glaze Toggle**.

## 📱 Core UI Architecture

### 1. The Home Screen (The Mirror)
The app opens directly to a camera-like feed of your Circles.
- **The Default State (Glaze):** Every artifact is rendered as an **Aura** (generative abstract art). You see the "vibe" and the "presence" of your friends without the metadata or pixels.
- **The Interaction (The Vue):** To see the content, the user must perform a physical gesture (e.g., long-press or a "swipe-down" motion).
    - This gesture triggers a **FaceID/TouchID** check.
    - Upon success, the shader's opacity drops, and the decrypted artifact is revealed.

### 2. The Circle Switcher (The Compass)
A haptic, circular menu at the bottom of the screen.
- **Navigation:** Dragging the thumb left/right rotates through your **Circle Ledger**.
- **Context:** Switching a Circle instantly changes the decryption key in volatile memory and updates the Aura palette to the new Circle's `glaze_salt`.

### 3. The Composition Mode (The Scramble)
- **Capture:** Photos/Videos are captured and immediately processed in RAM.
- **The Burn Timer:** A simple slider to set the artifact's lifespan (1h, 24h, Permanent).
- **The Seal:** Tapping "Seal" performs the AES-256 encryption and publishes the artifact to the network.

## 🖐️ Physicality & Haptics

Veu uses "Heavy Haptics" to simulate the weight of the cryptography.
- **Handshake Haptic:** A unique "heartbeat" vibration when two phones are performing an Emerald Handshake.
- **Burn Haptic:** A sharp, vanishing click when an artifact is deleted.
- **Vue Haptic:** A subtle, continuous "hum" while you are holding the screen to view decrypted content.

## 🛠️ View Controller Specification (iOS/SwiftUI)

- **`AuraView`**: The GLSL fragment shader container.
- **`SecureVault`**: A wrapper for `LocalAuthentication` that guards the "Vue" toggle.
- **`HapticEngine`**: Manages the `UIImpactFeedbackGenerator` for protocol events.

## 🚫 UI Anti-Patterns
- **No Screenshotting:** The app detects screenshots and automatically "Glazes" the content before the OS saves the image.
- **No Screen Recording:** Decrypted content is obscured in the system's screen-capture buffer.
- **No Cloud Backup:** The app explicitly opts out of the standard `Documents` directory iCloud sync to prevent PII leakage.