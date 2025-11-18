package com.example.flutter_gps_ar_fusion_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity: FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // This is the string that MUST match the Flutter code 
        val viewType = "arcore_view"
        
        // Get the BinaryMessenger
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // Register the factory
        flutterEngine.platformViewsController.registry.registerViewFactory(
            viewType,
            ArCoreViewFactory(messenger, this)
        )
    }
}