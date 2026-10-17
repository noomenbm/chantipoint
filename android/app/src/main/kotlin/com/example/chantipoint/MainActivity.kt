package com.example.chantipoint

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import com.example.chantipoint.journal.JournalChannel

class MainActivity : FlutterActivity() {
    private var journalChannel: JournalChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        journalChannel?.detach()
        journalChannel = JournalChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        journalChannel?.detach()
        journalChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
