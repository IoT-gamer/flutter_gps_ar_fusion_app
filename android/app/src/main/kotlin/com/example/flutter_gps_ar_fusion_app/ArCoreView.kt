package com.example.flutter_gps_ar_fusion_app

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.opengl.GLSurfaceView
import android.util.Log
import android.view.View
import androidx.core.content.ContextCompat
import com.google.ar.core.ArCoreApk
import com.google.ar.core.Earth
import com.google.ar.core.Config
import com.google.ar.core.GeospatialPose
import com.google.ar.core.Session
import com.google.ar.core.TrackingState
import com.google.ar.core.VpsAvailability
import com.google.ar.core.VpsAvailabilityFuture
import com.google.ar.core.exceptions.CameraNotAvailableException
import com.google.ar.core.exceptions.UnavailableApkTooOldException
import com.google.ar.core.exceptions.UnavailableArcoreNotInstalledException
import com.google.ar.core.exceptions.UnavailableDeviceNotCompatibleException
import com.google.ar.core.exceptions.UnavailableSdkTooOldException
import com.google.ar.core.exceptions.UnavailableUserDeclinedInstallationException
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import java.util.concurrent.atomic.AtomicBoolean
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10


import java.util.function.Consumer

/**
 * The actual PlatformView that Flutter will display.
 * It holds a reference to the custom GLSurfaceView.
 */
class ArCoreView(
    val context: Context,
    val activity: Activity,
    val viewId: Int,
    messenger: BinaryMessenger,
    creationParams: Map<String?, Any?>?
) : PlatformView {

    // The custom GLSurfaceView
    private val glSurfaceView = MyArGlSurfaceView(context, activity)

    // The MethodChannel to send data back to Flutter
    private val methodChannel = MethodChannel(messenger, "com.example.flutter_high_accuracy_gps_app/ar")

    // Flag to know if AR is initialized
    private val arInitialized = AtomicBoolean(false)

    init {
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "refinePosition" -> {
                    val lat = call.argument<Double>("latitude")
                    val lng = call.argument<Double>("longitude")
                    if (lat != null && lng != null) {
                        // Delegate to the renderer which holds the active session
                        glSurfaceView.renderer.checkAndRefineLocation(lat, lng, result)
                    } else {
                        result.error("INVALID_ARGS", "Missing lat/lng", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        // Check for ARCore availability and permissions *before* setting up the view.
        // This is a good place to do it, as the view is being created.
        if (checkArCoreAndPermissions()) {
            // Pass the method channel to the renderer so it can send updates
            glSurfaceView.renderer.setMethodChannel(methodChannel)
            arInitialized.set(true)
        } else {
            // If setup fails, we can't proceed.
            // In a real app, you might show an error message.
            Log.e("ArCoreView", "ARCore setup failed.")
        }

        // Start the GLSurfaceView's render loop
        glSurfaceView.onResume()
    }

    /**
     * Checks for Camera permission and ARCore availability.
     */
    private fun checkArCoreAndPermissions(): Boolean {
        // Check for Camera Permission
        val hasCameraPermission = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.CAMERA
        ) == PackageManager.PERMISSION_GRANTED

        if (!hasCameraPermission) {
            Log.e(
                "ArCoreView",
                "Camera permission is not granted. " +
                        "Please request it in your Flutter app before showing the AR view."
            )
            // Your main.dart already requests location, but not camera.
            // You MUST request camera permission from Flutter.
            return false
        }

        // Check for ARCore availability
        val availability = ArCoreApk.getInstance().checkAvailability(context)
        if (availability.isTransient) {
            // ARCore is currently installing or updating. Try again later.
            Log.w("ArCoreView", "ARCore is in a transient state. Retrying...")
            return false // Or implement a retry mechanism
        }

        if (!availability.isSupported) {
            Log.e("ArCoreView", "ARCore is not supported on this device.")
            return false
        }
        
        // ARCore is supported, but may not be installed.
        // We'll handle the installation request in the renderer's onResume.
        
        Log.i("ArCoreView", "Camera permission and ARCore support are OK.")
        return true
    }

    override fun getView(): View {
        return glSurfaceView
    }

    override fun dispose() {
        // This is critical. Pause the GLSurfaceView and session.
        glSurfaceView.onPause()
        Log.d("ArCoreView", "View $viewId disposed")
    }
}

/**
 * Your custom GLSurfaceView.
 */
class MyArGlSurfaceView(context: Context, activity: Activity) : GLSurfaceView(context) {

    val renderer: MyArRenderer

    init {
        // Use an OpenGL ES 2.0 context.
        setEGLContextClientVersion(2)

        // Set up the renderer
        renderer = MyArRenderer(context, activity)
        setRenderer(renderer)

        // Render continuously for AR
        renderMode = RENDERMODE_CONTINUOUSLY
    }

    // Pass lifecycle events to the renderer
    override fun onResume() {
        super.onResume()
        renderer.onResume()
    }

    override fun onPause() {
        renderer.onPause()
        super.onPause()
    }
}

/**
 * Custom Renderer.
 * This is where all ARCore session logic and rendering happens.
 */
class MyArRenderer(
    private val context: Context,
    private val activity: Activity
) : GLSurfaceView.Renderer {

    private var methodChannel: MethodChannel? = null
    private val mainThreadHandler = Handler(Looper.getMainLooper())
    
    // ARCore session and components
    private var session: Session? = null
    private val backgroundRenderer = BackgroundRenderer()
    
    // Flag to handle ARCore installation
    private var installRequested = false

    private var lastTrackingState: TrackingState? = null

    fun setMethodChannel(channel: MethodChannel) {
        this.methodChannel = channel
    }

    /**
     * Called when the GLSurfaceView's lifecycle is resumed.
     * This is where we create and resume the ARCore Session.
     */
    fun onResume() {
        if (session == null) {
            try {
                // Check for ARCore installation
                when (ArCoreApk.getInstance().requestInstall(
                    activity,
                    !installRequested
                )) {
                    ArCoreApk.InstallStatus.INSTALLED -> {
                        // ARCore is installed. Create the session.
                        session = Session(context)
                        Log.i("MyArRenderer", "ARCore session created.")
                    }
                    ArCoreApk.InstallStatus.INSTALL_REQUESTED -> {
                        // ARCore not installed, and user was prompted.
                        // We'll be called again when the app resumes.
                        installRequested = true
                        return
                    }
                }
            } catch (e: Exception) {
                // Handle all exceptions from ARCore installation/session creation
                Log.e("MyArRenderer", "Failed to create ARCore session", e)
                when (e) {
                    is UnavailableArcoreNotInstalledException,
                    is UnavailableUserDeclinedInstallationException -> {
                        Log.e("MyArRenderer", "ARCore not installed or user declined.")
                    }
                    is UnavailableApkTooOldException -> Log.e("MyArRenderer", "ARCore APK is too old.")
                    is UnavailableSdkTooOldException -> Log.e("MyArRenderer", "ARCore SDK is too old.")
                    is UnavailableDeviceNotCompatibleException -> Log.e("MyArRenderer", "ARCore not supported on this device.")
                    else -> Log.e("MyArRenderer", "Unknown ARCore error", e)
                }
                return // Can't proceed
            }
        }
        
        // Configure and resume the session
        try {
            session?.let {
                val config = Config(it)
                // Use LATEST_CAMERA_IMAGE for responsiveness
                config.updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE

                if (it.isGeospatialModeSupported(Config.GeospatialMode.ENABLED)) {
                    config.geospatialMode = Config.GeospatialMode.ENABLED
                }                

                it.configure(config)
                it.resume()
                Log.i("MyArRenderer", "ARCore session resumed.")
            }
        } catch (e: CameraNotAvailableException) {
            Log.e("MyArRenderer", "Camera not available. Please restart the app.", e)
            session = null
        }
    }

    /**
     * Called when the GLSurfaceView's lifecycle is paused.
     */
    fun onPause() {
        // Pause the session
        session?.let {
            it.pause()
            Log.i("MyArRenderer", "ARCore session paused.")
        }
    }

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        // Initialize GL components for the background renderer
        backgroundRenderer.createOnGlThread()
    }

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        // Update the display geometry
        session?.setDisplayGeometry(0, width, height) // Assuming portrait
    }

    override fun onDrawFrame(gl: GL10?) {
        // Get the current session and frame
        val localSession = session ?: return
        
        try {
            // Set texture and update the session to get a new frame
            localSession.setCameraTextureName(backgroundRenderer.textureId)
            val frame = localSession.update()

            // Draw the camera background
            backgroundRenderer.draw(frame)

            // Get the camera and its tracking state
            val camera = frame.camera

            val currentState = camera.trackingState
            if (currentState != lastTrackingState) {
                Log.i("MyArRenderer", "Tracking state changed to: $currentState")
                mainThreadHandler.post {
                    // Send the new status to Flutter
                    methodChannel?.invokeMethod("onTrackingStateUpdate", currentState.toString())
                }
                lastTrackingState = currentState
            }

            if (camera.trackingState == TrackingState.TRACKING) {
                // ARCore is actively tracking the environment

                // Get the camera pose
                val pose = camera.pose
                val translation = pose.translation // float[3] {x, y, z}

                // Format as a List<Double> for the MethodChannel
                val poseList = listOf(
                    translation[0].toDouble(),
                    translation[1].toDouble(),
                    translation[2].toDouble()
                )
                
                // Send the pose update back to Flutter ON THE MAIN THREAD
                mainThreadHandler.post {
                    methodChannel?.invokeMethod("onArPoseUpdate", poseList)
                }

                // TODO: Render any virtual objects (e.g., detected planes)
                
            } else {
                // Tracking was lost (e.g., camera covered)
                // You could send a status update to Flutter here
            }

        } catch (e: CameraNotAvailableException) {
            Log.e("MyArRenderer", "Camera not available", e)
        } catch (e: Exception) {
            Log.e("MyArRenderer", "Exception during onDrawFrame", e)
        }
    }

    fun checkAndRefineLocation(lat: Double, lng: Double, result: MethodChannel.Result) {
        val localSession = session ?: return result.error("NO_SESSION", "AR Session is null", null)

        // Check availability asynchronously
        val future = localSession.checkVpsAvailabilityAsync(
            lat,
            lng,
            Consumer { availability ->
                // This runs on the main thread
                if (availability != VpsAvailability.AVAILABLE) {
                    result.error("VPS_UNAVAILABLE", "VPS is not available at this location ($availability)", null)
                    return@Consumer
                }

                // VPS is available, now check if we are tracking
                val earth = localSession.earth
                if (earth?.trackingState == com.google.ar.core.TrackingState.TRACKING) {
                    val pose = earth.cameraGeospatialPose
                    
                    // Optional: Enforce high accuracy before accepting
                    // if (pose.horizontalAccuracy > 5.0) { ... }

                    val response = mapOf(
                        "latitude" to pose.latitude,
                        "longitude" to pose.longitude,
                        "heading" to pose.heading,
                        "accuracy" to pose.horizontalAccuracy
                    )
                    result.success(response)
                } else {
                    result.error("NOT_TRACKING", "VPS available, but camera not yet localized. Look around buildings.", null)
                }
            }
        )
    }    
}