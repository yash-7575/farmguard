package com.example.farmguard_camera

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "farmguard_camera/settings",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "openAppSettings" -> openAppSettings(result)
                "requestCameraPermission" -> requestCameraPermission(result)
                else -> result.notImplemented()
            }
        }
    }

    private fun openAppSettings(result: MethodChannel.Result) {
        try {
            val intent = Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", packageName, null),
            )
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            result.success(null)
        } catch (e: Exception) {
            result.error("settings_error", e.message, null)
        }
    }

    /**
     * Requests the CAMERA permission and reports the outcome to Dart as
     * "granted", "denied" (deniable again, OS will re-prompt) or
     * "permanentlyDenied" (user must enable it in system settings).
     *
     * Requesting here (instead of letting YOLOView prompt natively) keeps the
     * permission outcome visible to the Dart state machine, and guarantees
     * YOLOView only ever mounts with the permission already granted.
     */
    private fun requestCameraPermission(result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success("granted")
            return
        }
        if (pendingPermissionResult != null) {
            result.error("busy", "A permission request is already in progress.", null)
            return
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.CAMERA),
            REQUEST_CAMERA_PERMISSION,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_CAMERA_PERMISSION) return
        val pending = pendingPermissionResult ?: return
        pendingPermissionResult = null
        val granted =
            grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
        when {
            granted -> pending.success("granted")
            // If the OS no longer offers a rationale, the user chose
            // "don't ask again": only Settings can restore access.
            shouldShowRequestPermissionRationale(Manifest.permission.CAMERA) ->
                pending.success("denied")
            else -> pending.success("permanentlyDenied")
        }
    }

    companion object {
        private const val REQUEST_CAMERA_PERMISSION = 4101
    }
}
