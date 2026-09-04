package com.zond.xtremio

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView

/**
 * One text field on a screen of its own, so a remote can type into it.
 *
 * Flutter sets `IME_FLAG_NO_FULLSCREEN` on every field it creates, and Dart
 * cannot unset it. On a phone that keeps the keyboard from swallowing the
 * screen; on a television it is the flag that makes typing impossible,
 * because fullscreen ("extract") mode is precisely the mode in which the
 * keyboard takes window focus and owns the D-pad. Without it the app window
 * keeps focus, every D-pad press reaches Flutter and moves Flutter's focus,
 * and the keyboard cannot move its own selection.
 *
 * This screen is a plain [EditText] with plain [EditorInfo] options — no
 * such flag — so Gboard for Android TV goes fullscreen and the remote
 * drives it. Back cancels and returns nothing; Done returns the string.
 *
 * Started by [MainActivity] for the `editText` call on the `xtremio/device`
 * channel (`lib/shell/tv_text_entry.dart`), and by nothing else: it is not
 * exported.
 */
class TextEntryActivity : Activity() {
    private lateinit var field: EditText

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val kind = intent.getStringExtra(EXTRA_KIND) ?: KIND_TEXT
        val secret = kind == KIND_PASSWORD
        // A password must not be screenshotted, recorded or cast, nor show
        // as this task's thumbnail in recents.
        if (secret) window.setFlags(SECURE, SECURE)

        field = EditText(this).apply {
            isSingleLine = true
            // Last, and after isSingleLine: setting the input type is what
            // installs the password mask, and setSingleLine would replace
            // that transformation with its own and show the password.
            inputType = inputTypeFor(kind)
            imeOptions = imeOptionsFor(secret)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, FIELD_SP)
            if (secret && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
            }
            // The system restores what was being typed itself; only a fresh
            // screen takes the value the app is holding.
            if (savedInstanceState == null) {
                setText(intent.getStringExtra(EXTRA_VALUE).orEmpty())
                setSelection(text.length)
            }
            setOnEditorActionListener { _, actionId, event ->
                val done = actionId == EditorInfo.IME_ACTION_DONE ||
                    actionId == EditorInfo.IME_ACTION_GO ||
                    actionId == EditorInfo.IME_ACTION_SEARCH ||
                    // A hardware Enter arrives as IME_NULL, twice: once
                    // down, once up.
                    (actionId == EditorInfo.IME_NULL && event?.action == KeyEvent.ACTION_DOWN)
                if (done) confirm()
                done
            }
        }
        setContentView(screen(intent.getStringExtra(EXTRA_LABEL).orEmpty()))
        field.requestFocus()
    }

    /** The label over the field, then the field, down the middle. */
    private fun screen(label: String): View {
        val margin = (resources.displayMetrics.widthPixels * OVERSCAN).toInt()
        val heading = TextView(this).apply {
            text = label
            visibility = if (label.isEmpty()) View.GONE else View.VISIBLE
            setTextSize(TypedValue.COMPLEX_UNIT_SP, LABEL_SP)
        }
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(margin, margin, margin, margin)
            addView(heading, ViewGroup.LayoutParams(MATCH, WRAP))
            addView(field, ViewGroup.LayoutParams(MATCH, WRAP))
        }
    }

    private fun confirm() {
        setResult(RESULT_OK, Intent().putExtra(EXTRA_VALUE, field.text.toString()))
        finish()
    }

    companion object {
        const val EXTRA_LABEL = "com.zond.xtremio.text_entry.LABEL"
        const val EXTRA_VALUE = "com.zond.xtremio.text_entry.VALUE"
        const val EXTRA_KIND = "com.zond.xtremio.text_entry.KIND"

        // The kinds `TvTextKind` (lib/shell/tv_text_entry.dart) sends, by
        // its enum's own names. Anything else is treated as plain text.
        const val KIND_TEXT = "text"
        const val KIND_EMAIL = "email"
        const val KIND_PASSWORD = "password"
        const val KIND_URL = "url"

        private const val SECURE = WindowManager.LayoutParams.FLAG_SECURE
        private const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        private const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT

        /** The fraction of each edge a television may crop; TvDensity's. */
        private const val OVERSCAN = 0.05f
        private const val LABEL_SP = 20f
        private const val FIELD_SP = 24f

        fun intentFor(
            context: Context,
            label: String,
            value: String,
            kind: String,
        ): Intent = Intent(context, TextEntryActivity::class.java)
            .putExtra(EXTRA_LABEL, label)
            .putExtra(EXTRA_VALUE, value)
            .putExtra(EXTRA_KIND, kind)

        private fun inputTypeFor(kind: String): Int = InputType.TYPE_CLASS_TEXT or
            when (kind) {
                KIND_EMAIL -> InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS
                KIND_PASSWORD -> InputType.TYPE_TEXT_VARIATION_PASSWORD
                KIND_URL -> InputType.TYPE_TEXT_VARIATION_URI
                else -> InputType.TYPE_TEXT_VARIATION_NORMAL
            }

        /**
         * Done, and — for a password — a keyboard that learns nothing from
         * what is typed. Never `IME_FLAG_NO_FULLSCREEN`: that flag is the
         * whole bug this screen exists for.
         */
        private fun imeOptionsFor(secret: Boolean): Int {
            var options = EditorInfo.IME_ACTION_DONE
            if (secret && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                options = options or EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
            }
            return options
        }
    }
}
