package com.zond.xtremio

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Must run before the Flutter engine starts Dart: RustLib.init() may
        // issue HTTPS requests right away.
        NativeInit.initTlsVerifier(applicationContext)
        super.onCreate(savedInstanceState)
    }
}
