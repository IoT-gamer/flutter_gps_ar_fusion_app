# Flutter GPS AR Fusion App

![Work in Progress](https://img.shields.io/badge/status-work%20in%20progress-yellow)

A Flutter application designed to achieve centimeter-level relative precision and trajectory smoothness by fusing **GNSS (Global Navigation Satellite System)** data with **Visual Inertial Odometry (VIO)** from Google ARCore.

This project uses a custom Kalman Filter to bridge the gap between slow, noisy satellite updates with high-frequency visual tracking data. This results in a **jitter-free** and **continuous path**.

The application now visualizes this "jitter-free" path on an interactive map.

note: the **absolute global position** will still have an error of several meters

## 🚀 Features

* **Sensor Fusion:** Combines absolute positioning (GPS) with precise relative tracking (ARCore VIO).

* **Real-time Tuning:** Includes a **"Fusion Balance" slider** to dynamically adjust the Kalman Filter's trust:
    * **Trust GPS:** Rely more on satellite data (fixes drift, but adds jitter).
    * **Trust AR:** Rely more on visual odometry (smooth path, but susceptible to drift).

* **Interactive Map Visualization:** Uses `flutter_map` (OpenStreetMap) to draw the user's path in real-time.
    * **Blue Line:** Represents the smooth, fused trajectory.
    * **Red Marker:** Represents the current estimated position.

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
    * The map polyline extends immediately, providing smooth visual feedback.

2. **Update (Lower Frequency):**
    * The `geolocator` plugin provides absolute GPS coordinates.
    * The Kalman Filter **updates** (corrects) the predicted state based on the GPS reading and its accuracy confidence.
    * The map trajectory is "corrected" to align with the absolute coordinates.

## 📦 Tech Stack
* **Frontend:** Flutter (Dart)
* **Native Module:** Kotlin (Android)
* **AR Engine:** Google ARCore SDK (via `GLSurfaceView` and custom Renderer) 
* **Mapping:** `flutter_map` with OpenStreetMap tiles
* **Math:** `vector_math_64` (Matrix operations), `latlong2` (Geospatial calculations)
* **Location:** `geolocator` plugin for GPS data

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

2.  **Initialization:**
    * The app waits for a high-accuracy GPS fix (< 20m accuracy) to initialize the Kalman Filter. 
    * Once locked, the map will center on your location and the AR session will begin.
    
3.  **Tracking:**
    * Walk normally holding the phone up (camera unblocked).
    * Watch the **Blue Polyline** on the map. It will draw smoothly in real-time as you walk.
    * If the AR tracking drifts, the line will gently correct itself when the next high-quality GPS point arrives.

4. **Tuning:** Use the slider at the bottom of the screen:
    * **Slide Left (Trust GPS):** Use this if the blue line is drifting through buildings. The path will snap to the raw GPS points.
    * **Slide Right (Trust AR):** Use this if the GPS is jittering wildly. The path will become very smooth but may drift over long distances.

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