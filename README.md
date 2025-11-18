# Flutter GPS AR Fusion App

![Work in Progress](https://img.shields.io/badge/status-work%20in%20progress-yellow)

A Flutter application designed to achieve centimeter-level relative precision and trajectory smoothness by fusing **GNSS (Global Navigation Satellite System)** data with **Visual Inertial Odometry (VIO)** from Google ARCore.

This project uses a custom Kalman Filter to bridge the gap between slow, noisy satellite updates with high-frequency visual tracking data. This results in a **jitter-free** and **continuous path**.

note: the **absolute global position** will still have an error of several meters

## 🚀 Features

* **Sensor Fusion:** Combines absolute positioning (GPS) with precise relative tracking (ARCore VIO).

* **Custom Kalman Filter:** Implements a 4-state Kalman filter (Latitude, Longitude, Velocity North, Velocity East) to merge data sources intelligently.

* **Native ARCore Integration:** Uses a custom Android Platform View (`ArCoreView`) written in Kotlin to extract raw pose data directly from the AR session.

* **Real-time Dashboard:** Displays raw GPS data, AR relative displacement, and the final fused coordinates side-by-side.

* **Permissions Handling:** Manages run-time requests for Camera (AR) and Location (Fine/Coarse) permissions.

## 🛠 Architecture

The app operates using a Predict-Update cycle:

1. **Prediction (High Frequency):**
    * The native Android layer captures the camera's motion using ARCore's `TrackingState` and `Pose`.
    * This relative movement (*x*, *y*, *z*) is sent to Flutter via `MethodChannel`.
    * The Kalman Filter **predicts** the new geolocation based on this visual displacement.

2. **Update (Lower Frequency):**
    * The `geolocator` plugin provides absolute GPS coordinates.
    * The Kalman Filter **updates** (corrects) the predicted state based on the GPS reading and its accuracy confidence.

## 📦 Tech Stack
* **Frontend:** Flutter (Dart)
* **Native Module:** Kotlin (Android)
* **AR Engine:** Google ARCore SDK (via `GLSurfaceView` and custom Renderer) 
* **Math:** `vector_math_64` for matrix operations in the filter 
* **Plugins:**
    * `geolocator`
    * `permission_handler`
    * `vector_math`

## 📋 Prerequisites
* **Hardware:** An Android device that supports **Google ARCore** (Google Play Services for AR).
* **OS:** Android 7.0 (Nougat) or later.
* **Environment:** Flutter SDK installed.

Note: This project currently supports **Android only**. The iOS implementation is a placeholder stub,

## ⚙️ Installation

1. **Clone the repository:**
   ```bash
    git clone https://github.com/IoT-gamer/flutter_gps_ar_fusion_app.git
    cd flutter_gps_ar_fusion_app
   ```

2. **Install dependencies:**
    ```bash
    flutter pub get
    ```
3. **Run on a physical device:**
    * Connect your ARCore-supported Android device via USB.
    * Ensure "Developer Options" and "USB Debugging" are enabled.
    ```bash
    flutter run
    ```

## 📱 Usage

1. **Grant Permissions:** Upon launch, accept the prompts for **Camera** (required for AR tracking) and **Location** (required for GPS).

2. **Wait for Initialization:**
    * **Step 1:** The app waits for a high-accuracy GPS fix (< 20m accuracy) to initialize the Kalman Filter.
    * **Step 2:** Once GPS is locked, the AR session starts.

3. **Tracking:**

    * Walk normally holding the phone up (camera unblocked).

    * The **"Fused Position"** card will update smoothly as you move, even if the GPS signal lags or jitters.

    * Status indicators will show "AR Tracking Active" when fusion is working.

## 📂 Project Structure

```
lib/
├── main.dart                 # Main Flutter UI, Kalman Filter logic, and MethodChannel handling
android/
├── app/src/main/kotlin/com/example/flutter_gps_ar_fusion_app/
    ├── MainActivity.kt       # Registers the Native View Factory
    ├── ArCoreView.kt         # The PlatformView wrapper
    ├── ArCoreViewFactory.kt  # Factory for creating the view
    ├── MyArRenderer.kt       # Handles AR session, camera frame updates, and pose extraction
    └── BackgroundRenderer.kt # Renders the camera feed to the GLSurface
```

## ⚠️ Known Limitations
**Drift:** Pure visual odometry drifts over time. This is mitigated by the GPS updates in the Kalman Filter, but prolonged operation without GPS (e.g., tunnels) will eventually drift.

**Initialization:** The app currently blocks visualization until a "Good" GPS fix is found. If testing indoors, you may need to temporarily bypass the `!_isKalmanInitialized` check in `main.dart`.

## 🤝 Contributing
Contributions are welcome! Please feel free to submit a Pull Request.

## 📜 License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details