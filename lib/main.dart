import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'dart:io' show Platform;
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vector_math/vector_math_64.dart' as vector;
import 'dart:async';
import 'dart:math';

void main() {
  runApp(const HighAccuracyGpsApp());
}

class HighAccuracyGpsApp extends StatelessWidget {
  const HighAccuracyGpsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'High-Accuracy GPS',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const GpsFusionScreen(),
    );
  }
}

class GpsFusionScreen extends StatefulWidget {
  const GpsFusionScreen({super.key});

  @override
  State<GpsFusionScreen> createState() => _GpsFusionScreenState();
}

class _GpsFusionScreenState extends State<GpsFusionScreen> {
  // --- Controllers and Subscriptions ---
  StreamSubscription<Position>? _positionStreamSubscription;

  // MethodChannel for native AR communication
  static const _arChannel = MethodChannel(
    'com.example.flutter_high_accuracy_gps_app/ar',
  );

  // --- State Variables ---
  String _arStatus = "Initializing ARCore...";
  Position? _rawGpsPosition;
  vector.Vector3? _arPosition; // Relative position from ARCore
  vector.Vector3? _lastArPosition;
  KalmanPosition? _fusedPosition;

  // --- Kalman Filter ---
  late KalmanFilter _kalmanFilter;
  bool _isKalmanInitialized = false;
  bool _permissionsGranted = false;

  // --- Map Variables ---
  final MapController _mapController = MapController();
  final List<LatLng> _pathHistory = [];

  @override
  void initState() {
    super.initState();
    _initializeServices();
  }

  Future<void> _initializeServices() async {
    // 1. Request Permissions
    await _requestPermissions();

    // 2. Initialize Kalman Filter (will be re-initialized on first GPS fix)
    _kalmanFilter = KalmanFilter();

    // 3. Start listening to GPS updates
    _startGpsUpdates();

    // 5. ADDED: Set up the MethodChannel handler
    _arChannel.setMethodCallHandler(_onPlatformChannelMessage);
  }

  Future<void> _requestPermissions() async {
    // Request Location
    LocationPermission locationPermission = await Geolocator.checkPermission();
    if (locationPermission == LocationPermission.denied) {
      locationPermission = await Geolocator.requestPermission();
    }

    // Request Camera
    var cameraStatus = await Permission.camera.status;
    if (cameraStatus.isDenied) {
      cameraStatus = await Permission.camera.request();
    }

    // Update state ONLY if both are granted
    if (locationPermission != LocationPermission.denied &&
        locationPermission != LocationPermission.deniedForever &&
        cameraStatus.isGranted) {
      setState(() {
        _permissionsGranted = true;
      });
    } else {
      // Handle the case where user denies permission
      setState(() {
        _arStatus = "Location and Camera permissions are required.";
      });
    }
  }

  void _startGpsUpdates() {
    const LocationSettings locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 1, // Notify me every 1 meter
    );
    _positionStreamSubscription =
        Geolocator.getPositionStream(
          locationSettings: locationSettings,
        ).listen((Position position) {
          setState(() {
            _rawGpsPosition = position;
          });

          if (!_isKalmanInitialized && position.accuracy < 20) {
            // First good GPS fix. Initialize the Kalman filter's state.
            _kalmanFilter.initialize(
              lat: position.latitude,
              lon: position.longitude,
              accuracy: position.accuracy,
            );
            setState(() {
              _fusedPosition = KalmanPosition(
                position.latitude,
                position.longitude,
              );
              _isKalmanInitialized = true;
              if (!_arStatus.contains("AR Status") &&
                  !_arStatus.contains("Tracking")) {
                _arStatus = "Kalman Initialized. Waiting for AR updates...";
              }
            });
          } else if (_isKalmanInitialized) {
            // We have a new GPS measurement. Use it to UPDATE the Kalman filter.
            _kalmanFilter.update(
              lat: position.latitude,
              lon: position.longitude,
              accuracy: position.accuracy,
            );
            final state = _kalmanFilter.getState();

            // Update path
            _updatePathAndMap(state[0], state[2]);

            setState(() {
              _fusedPosition = KalmanPosition(state[0], state[2]);
            });
          }
        });
  }

  // This function now handles pose updates from the native side
  Future<void> _onPlatformChannelMessage(MethodCall call) async {
    print("FLUTTER RECEIVED: ${call.method} -> ${call.arguments}");
    if (call.method == 'onArPoseUpdate') {
      final List<double>? translation = call.arguments?.cast<double>();
      if (translation == null || translation.length < 3) return;

      if (!_isKalmanInitialized) return;

      final currentArPosition = vector.Vector3(
        translation[0],
        translation[1],
        translation[2],
      );

      setState(() {
        _arPosition = currentArPosition;
        // Only set "Active" if it's not already set, to avoid flicker
        if (_arStatus != "AR Tracking Active") {
          _arStatus = "AR Tracking Active";
        }
      });

      if (_lastArPosition != null) {
        // This logic is identical to the old _onArCoreUpdate
        final delta = currentArPosition - _lastArPosition!;
        // We assume a simple flat earth model for local movement.
        // Y is typically 'up' in ARCore, so we use X and Z for horizontal movement.
        // IMPORTANT: ARCore's Z-axis is negative "forward"
        final deltaNorth = -delta.z;
        final deltaEast = delta.x;

        // Use this change in position to PREDICT our next state
        _kalmanFilter.predict(deltaNorth: deltaNorth, deltaEast: deltaEast);
        final state = _kalmanFilter.getState();

        // Update path
        _updatePathAndMap(state[0], state[2]);

        setState(() {
          _fusedPosition = KalmanPosition(state[0], state[2]);
        });
      }
      _lastArPosition = currentArPosition;
    } else if (call.method == 'onTrackingStateUpdate') {
      final String status = call.arguments as String;

      setState(() {
        // ALWAYS update the status
        _arStatus = "AR Status: $status";

        // If we are NOT tracking, clear the AR position and reset
        if (status != "TRACKING") {
          _arPosition = null;
          _lastArPosition = null;
        }
      });
      print("ARCore Tracking State: $status");
    }
  }

  // Helper to update path and map center
  void _updatePathAndMap(double lat, double lon) {
    final newPoint = LatLng(lat, lon);

    _pathHistory.add(newPoint);

    // Optional: Limit path history to last 500 points to save memory
    if (_pathHistory.length > 1000) {
      _pathHistory.removeAt(0);
    }

    // Move the map camera to follow the user
    _mapController.move(newPoint, 18.0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sensor Fusion GPS')),
      body: Column(
        children: [
          // Top Half: AR View (Camera)
          Expanded(flex: 2, child: _buildArView()),

          // Bottom Half: Map with Path
          Expanded(
            flex: 3,
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    // Initialize center (default to 0,0 if not ready)
                    initialCenter: _fusedPosition != null
                        ? LatLng(
                            _fusedPosition!.latitude,
                            _fusedPosition!.longitude,
                          )
                        : const LatLng(0, 0),
                    initialZoom: 18.0,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName:
                          'com.example.flutter_gps_ar_fusion_app',
                    ),
                    // The Blue Line (Fused Path)
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: _pathHistory,
                          strokeWidth: 4.0,
                          color: Colors.blue,
                        ),
                      ],
                    ),
                    // The Current Position Marker (Red Dot)
                    if (_fusedPosition != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: LatLng(
                              _fusedPosition!.latitude,
                              _fusedPosition!.longitude,
                            ),
                            width: 20,
                            height: 20,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.red,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2,
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    blurRadius: 5,
                                    color: Colors.black26,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),

                // Overlay the status card on top of the map
                Positioned(
                  top: 10,
                  left: 10,
                  right: 10,
                  child: _buildStatusCard(),
                ),

                // Optional: Toggle to show stats logic could go here
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Helper widget to build the correct PlatformView
  Widget _buildArView() {
    // This is the identifier that you will use in your native Android code
    // to register the PlatformViewFactory.
    const String arViewType = 'arcore_view';

    if (!_permissionsGranted) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text("Waiting for permissions..."),
          ],
        ),
      );
    }

    if (Platform.isAndroid) {
      return AndroidView(
        viewType: arViewType,
        // Pass creation parameters if needed (e.g., API keys)
        // creationParams: <String, dynamic>{},
        // creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: (int id) {
          print("Native ARCore View (id: $id) created.");
          // You can send initial setup messages here if needed
          // _arChannel.invokeMethod('startSession', {'id': id});
        },
      );
    } else if (Platform.isIOS) {
      // TODO: For iOS, use UiKitView and have a corresponding
      // native ARKit implementation.
      return UiKitView(
        viewType:
            'arkit_view', // This ID must match the native iOS registration
        onPlatformViewCreated: (int id) {
          print("Native ARKit View (id: $id) created.");
        },
      );
    }

    // Fallback for other platforms
    return const Center(child: Text("AR not supported on this platform"));
  }

  Widget _buildStatusCard() {
    final bool isReady = _isKalmanInitialized && _arPosition != null;
    return Card(
      color: isReady ? Colors.green.shade100 : Colors.orange.shade100,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Row(
          children: [
            Icon(
              isReady ? Icons.check_circle : Icons.hourglass_top,
              color: isReady ? Colors.green.shade800 : Colors.orange.shade800,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _arStatus,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: isReady
                      ? Colors.green.shade800
                      : Colors.orange.shade800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoCard(
    String title,
    List<Widget> children, {
    Color? cardColor,
  }) {
    return Card(
      elevation: 2,
      color: cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const Divider(height: 20),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(
    String label,
    String value, {
    bool isHighlighted = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.black54)),
          Text(
            value,
            style: TextStyle(
              fontWeight: isHighlighted ? FontWeight.bold : FontWeight.normal,
              fontSize: isHighlighted ? 16 : 14,
              color: isHighlighted ? Colors.deepPurple : Colors.black,
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _positionStreamSubscription?.cancel();
    super.dispose();
  }
}

// --- Helper Data Class ---
class KalmanPosition {
  final double latitude;
  final double longitude;
  KalmanPosition(this.latitude, this.longitude);
}

// --- Kalman Filter Implementation ---

class KalmanFilter {
  // A simplified Kalman Filter for fusing GPS and Odometry data.
  // State vector: [latitude, velocity_north, longitude, velocity_east]
  // For simplicity, this uses a constant velocity model.

  late vector.Vector4 _x; // State vector [lat, v_n, lon, v_e]
  late vector.Matrix4 _p; // State covariance matrix

  // Process noise covariance. Represents the uncertainty in our motion model.
  // Higher values mean we trust the model less.
  final vector.Matrix4 _q = vector.Matrix4.identity()
    ..storage[0] = 0.1
    ..storage[5] = 0.5
    ..storage[10] = 0.1
    ..storage[15] = 0.5;

  // Measurement noise covariance. Represents the uncertainty in our sensor readings (GPS).
  late vector.Matrix2 _r;

  // State transition matrix. Projects the state forward in time.
  vector.Matrix4 _f(double dt) => vector.Matrix4(
    1,
    0,
    0,
    0,
    dt,
    1,
    0,
    0, // position = old_position + velocity * dt
    0,
    0,
    1,
    0,
    0,
    0,
    dt,
    1,
  )..transpose();

  // Measurement matrix. Maps the state space to the measurement space.
  final vector.Matrix4 _h = vector.Matrix4(
    1,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
  )..transpose(); // We only measure position (lat, lon), not velocity.

  void initialize({
    required double lat,
    required double lon,
    required double accuracy,
  }) {
    _x = vector.Vector4(lat, 0, lon, 0); // Initial state (lat, v_n, lon, v_e)
    _p =
        vector.Matrix4.identity() * (accuracy * accuracy); // Initial covariance
    _r = vector.Matrix2(accuracy, 0, 0, accuracy); // Measurement noise
  }

  // PREDICT step: Use motion model (ARCore odometry) to predict next state.
  void predict({required double deltaNorth, required double deltaEast}) {
    // This is a simplified predict step where ARCore provides the state change directly.
    // A full implementation would use a time delta (dt) and the state transition matrix _f.

    // Convert meters to degrees (approximate)
    const metersPerDegreeLat = 111132.954;
    double lat = _x[0];
    double lon = _x[2];
    double deltaLat = deltaNorth / metersPerDegreeLat;
    double deltaLon =
        deltaEast / (metersPerDegreeLat * cos(vector.radians(lat)));

    // Update state based on odometry delta
    _x[0] += deltaLat; // latitude
    _x[2] += deltaLon; // longitude

    // We don't have velocity from ARCore directly, so we can estimate it,
    // but for this example, we keep it simple.
    // _x[1] = ... velocity north
    // _x[3] = ... velocity east

    // Increase uncertainty because we are predicting
    // In a full implementation: _p = _f * _p * _f.transpose() + _q;
    _p.add(_q);
  }

  // UPDATE step: Use sensor measurement (GPS) to correct the prediction.
  void update({
    required double lat,
    required double lon,
    required double accuracy,
  }) {
    // Update measurement noise based on current GPS accuracy
    // Use variance (accuracy^2), matching the initialization of _p
    final double variance = accuracy * accuracy;
    _r = vector.Matrix2(variance, 0, 0, variance);
    // [Original line: _r = vector.Matrix2(accuracy, 0, 0, accuracy);]

    // Measurement residual (the difference between measurement and prediction)
    final z = vector.Vector2(lat, lon);
    final hx = vector.Vector2(_x[0], _x[2]); // Predicted lat/lon from state
    final y = z - hx;

    // --- Standard Kalman Filter Equations ---

    // 1. PHT = P * H'
    // _p is (4x4). _h (which is H') is (4x2 padded). Result pht is (4x2 padded).
    final pht = _p.multiplied(_h);

    // 2. S = H * PHT + R
    // _h.transposed() (which is H) is (2x4 padded). pht is (4x2 padded).
    // The result 's' is a (4x4) matrix holding the (2x2) result.
    final s = _h.transposed().multiplied(pht);

    // Extract the 2x2 S matrix from the 4x4 padded result
    final s_2x2 = vector.Matrix2(
      s.storage[0], // col 0, row 0
      s.storage[1], // col 0, row 1
      s.storage[4], // col 1, row 0
      s.storage[5], // col 1, row 1
    );

    // Add measurement noise R (2x2)
    s_2x2.add(_r);

    // 3. S_inv = S.inverse()
    final sInv = s_2x2..invert();

    // 4. K = PHT * S_inv
    // K is (4x2). pht is (4x2 padded). sInv is (2x2).
    // We must manually multiply (4x2) * (2x2) as pht.multiplied(sInv) is invalid.

    final k =
        vector.Matrix4.zero(); // K will be stored as a (4x2 padded) Matrix4
    final phtStorage = pht.storage;
    final sInvStorage = sInv.storage;
    final kStorage = k.storage;

    // Manually compute K = PHT * sInv
    // K_col0 = PHT_col0 * sInv(0,0) + PHT_col1 * sInv(1,0)
    kStorage[0] =
        phtStorage[0] * sInvStorage[0] +
        phtStorage[4] * sInvStorage[1]; // K(0,0)
    kStorage[1] =
        phtStorage[1] * sInvStorage[0] +
        phtStorage[5] * sInvStorage[1]; // K(1,0)
    kStorage[2] =
        phtStorage[2] * sInvStorage[0] +
        phtStorage[6] * sInvStorage[1]; // K(2,0)
    kStorage[3] =
        phtStorage[3] * sInvStorage[0] +
        phtStorage[7] * sInvStorage[1]; // K(3,0)

    // K_col1 = PHT_col0 * sInv(0,1) + PHT_col1 * sInv(1,1)
    kStorage[4] =
        phtStorage[0] * sInvStorage[2] +
        phtStorage[4] * sInvStorage[3]; // K(0,1)
    kStorage[5] =
        phtStorage[1] * sInvStorage[2] +
        phtStorage[5] * sInvStorage[3]; // K(1,1)
    kStorage[6] =
        phtStorage[2] * sInvStorage[2] +
        phtStorage[6] * sInvStorage[3]; // K(2,1)
    kStorage[7] =
        phtStorage[3] * sInvStorage[2] +
        phtStorage[7] * sInvStorage[3]; // K(3,1)

    // 5. Update state: x = x + K * y
    // This is the manual (4x2) * (2x1) multiplication
    // This part was already correct in your file

    final k_mult_y = vector.Vector4.zero();
    k_mult_y[0] = kStorage[0] * y[0] + kStorage[4] * y[1];
    k_mult_y[1] = kStorage[1] * y[0] + kStorage[5] * y[1];
    k_mult_y[2] = kStorage[2] * y[0] + kStorage[6] * y[1];
    k_mult_y[3] = kStorage[3] * y[0] + kStorage[7] * y[1];

    _x.add(k_mult_y);

    // 6. Update covariance: P = (I - K * H) * P
    // K is (4x2 padded). H is (2x4 padded). K * H is (4x4 padded).
    final kh = k.multiplied(_h.transposed());

    final imkh = (vector.Matrix4.identity()..sub(kh));
    _p = imkh.multiplied(_p);
  }

  vector.Vector4 getState() => _x;
}
