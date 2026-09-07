package com.example.smartkiranashop

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.Result
import android.content.pm.PackageManager
import android.Manifest
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.santhosh.smartkiranashop/telephony"
    private val DEVICE_INFO_CHANNEL = "com.santhosh.smartkiranashop/device_info"
    private val FILE_PICKER_CHANNEL = "com.santhosh.smartkiranashop/file_picker"

    private var pendingResult: Result? = null
    private var filePickerResult: Result? = null

    private val PERMISSION_REQUEST_CODE = 4829
    private val FILE_PICKER_REQUEST_CODE = 4830

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── Telephony channel (existing) ────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "getDevicePhoneNumbers") {
                pendingResult = result
                if (hasRequiredPermissions()) {
                    result.success(getSimPhoneNumbers())
                } else {
                    requestRequiredPermissions()
                }
            } else {
                result.notImplemented()
            }
        }

        // ── Device info channel — Android ID for trial fingerprinting ───────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_INFO_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "getAndroidId") {
                try {
                    val androidId = Settings.Secure.getString(
                        contentResolver,
                        Settings.Secure.ANDROID_ID
                    )
                    result.success(androidId ?: "")
                } catch (e: Exception) {
                    result.success("")
                }
            } else {
                result.notImplemented()
            }
        }

        // ── File picker channel — opens Android Storage Access Framework ────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILE_PICKER_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickFile" -> {
                    filePickerResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                        // Accept any file — user will select .sbk
                        putExtra(Intent.EXTRA_MIME_TYPES, arrayOf(
                            "application/octet-stream",
                            "application/x-sbk",
                            "*/*"
                        ))
                    }
                    startActivityForResult(intent, FILE_PICKER_REQUEST_CODE)
                }
                else -> result.notImplemented()
            }
        }

        // ── WhatsApp direct file share channel ─────────────────────────────────
        val WHATSAPP_CHANNEL = "com.santhosh.smartkiranashop/whatsapp_share"
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WHATSAPP_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "shareFileDirectly") {
                val filePath = call.argument<String>("filePath")
                val phone = call.argument<String>("phone")
                val text = call.argument<String>("text")
                if (filePath != null && phone != null) {
                    try {
                        val file = File(filePath)
                        val uri = FileProvider.getUriForFile(this, "$packageName.provider", file)
                        
                        val intent = Intent(Intent.ACTION_SEND).apply {
                            type = "application/pdf"
                            putExtra(Intent.EXTRA_STREAM, uri)
                            clipData = android.content.ClipData.newRawUri(null, uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        
                        var cleanPhone = phone.replace(Regex("[^0-9]"), "")
                        if (cleanPhone.startsWith("0")) {
                            cleanPhone = cleanPhone.substring(1)
                        }
                        if (cleanPhone.startsWith("910") && cleanPhone.length == 13) {
                            cleanPhone = "91" + cleanPhone.substring(3)
                        }
                        if (cleanPhone.length == 10) {
                            cleanPhone = "91$cleanPhone"
                        }
                        intent.putExtra("jid", "$cleanPhone@s.whatsapp.net")
                        
                        if (text != null && text.isNotEmpty()) {
                            intent.putExtra(Intent.EXTRA_TEXT, text)
                        }

                        try {
                            val pkg = "com.whatsapp"
                            this.grantUriPermission(pkg, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            intent.setPackage(pkg)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            try {
                                val pkgW4b = "com.whatsapp.w4b"
                                this.grantUriPermission(pkgW4b, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                intent.setPackage(pkgW4b)
                                startActivity(intent)
                                result.success(true)
                            } catch (e2: Exception) {
                                result.error("NO_WHATSAPP", "WhatsApp is not installed or failed to start: ${e2.message}", null)
                            }
                        }
                    } catch (e: Exception) {
                        result.error("SHARE_ERROR", e.message, null)
                    }
                } else {
                    result.error("BAD_ARGS", "Missing arguments", null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode == FILE_PICKER_REQUEST_CODE) {
            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                val uri: Uri = data.data!!
                try {
                    // Copy the picked file to a temp path Flutter can read
                    val tempFile = File(cacheDir, "picked_backup.sbk")
                    contentResolver.openInputStream(uri)?.use { input ->
                        FileOutputStream(tempFile).use { output ->
                            input.copyTo(output)
                        }
                    }
                    filePickerResult?.success(tempFile.absolutePath)
                } catch (e: Exception) {
                    filePickerResult?.error("READ_ERROR", "Cannot read file: ${e.message}", null)
                }
            } else {
                filePickerResult?.success(null) // User cancelled
            }
            filePickerResult = null
        }
    }

    // ── Telephony helpers ───────────────────────────────────────────────────

    private fun hasRequiredPermissions(): Boolean {
        val hasPhoneState = ContextCompat.checkSelfPermission(this, Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED
        val hasSMS = ContextCompat.checkSelfPermission(this, Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED
        val hasPhoneNumbers = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ContextCompat.checkSelfPermission(this, Manifest.permission.READ_PHONE_NUMBERS) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
        return hasPhoneState || hasSMS || hasPhoneNumbers
    }

    private fun requestRequiredPermissions() {
        val permissions = mutableListOf(Manifest.permission.READ_PHONE_STATE, Manifest.permission.READ_SMS)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            permissions.add(Manifest.permission.READ_PHONE_NUMBERS)
        }
        ActivityCompat.requestPermissions(this, permissions.toTypedArray(), PERMISSION_REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMISSION_REQUEST_CODE) {
            val numbers = getSimPhoneNumbers()
            pendingResult?.success(numbers)
            pendingResult = null
        }
    }

    private fun getSimPhoneNumbers(): List<String> {
        val numbers = mutableListOf<String>()
        try {
            if (hasRequiredPermissions()) {
                val telephonyManager = getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
                telephonyManager?.line1Number?.let {
                    if (it.isNotEmpty()) numbers.add(it)
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
                    val subscriptionManager = getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE) as? SubscriptionManager
                    subscriptionManager?.activeSubscriptionInfoList?.forEach { info ->
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            try {
                                val num = subscriptionManager.getPhoneNumber(info.subscriptionId)
                                if (num.isNotEmpty() && !numbers.contains(num)) numbers.add(num)
                            } catch (e: Exception) {}
                        } else {
                            @Suppress("DEPRECATION")
                            info.number?.let {
                                if (it.isNotEmpty() && !numbers.contains(it)) numbers.add(it)
                            }
                        }
                    }
                }
            }
        } catch (e: Exception) { }
        return numbers
    }
}
