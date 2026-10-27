package com.example.chantipoint

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import com.example.chantipoint.journal.JournalChannel
import com.example.chantipoint.location.ForegroundLocationChannel
import com.example.chantipoint.activation.ActivationDocuments
import android.content.Intent

class MainActivity : FlutterActivity() {
    private var journalChannel: JournalChannel? = null
    private var noteChannel: JournalChannel? = null
    private var foregroundLocation: ForegroundLocationChannel? = null
    private var activationDocuments: ActivationDocuments? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        journalChannel?.detach()
        journalChannel = JournalChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        noteChannel?.detach()
        noteChannel = JournalChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger, noteMode = true)
        foregroundLocation?.detach()
        foregroundLocation = ForegroundLocationChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        activationDocuments?.detach()
        activationDocuments = ActivationDocuments(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onResume() { super.onResume(); foregroundLocation?.resume() }
    override fun onPause() { foregroundLocation?.pause(); super.onPause() }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (activationDocuments?.activityResult(requestCode, resultCode, data) != true) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (foregroundLocation?.permissionResult(requestCode) != true) {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        activationDocuments?.detach()
        activationDocuments = null
        foregroundLocation?.detach()
        foregroundLocation = null
        journalChannel?.detach()
        journalChannel = null
        noteChannel?.detach()
        noteChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
