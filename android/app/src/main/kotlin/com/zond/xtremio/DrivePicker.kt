package com.zond.xtremio

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.AuthorizationResult
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Google Drive's *native* picker, which is the only one on a phone that can
 * select more than one file.
 *
 * The web Google Picker gates selection on a Ctrl/Cmd key, so a phone holds
 * exactly one file — issuetracker.google.com/issues/334994030, reported in
 * April 2024 and still open. This path was measured at seven files in one
 * go. A phone without this app still gets the web page, so both exist.
 *
 * Two things about the request are load-bearing and neither is obvious:
 *
 *  * `PICKER_OAUTH_TRIGGER` is spelled `trigger_onepick` on the wire — the
 *    same parameter the web flow is refused for with `invalid_request`. What
 *    refuses it there is Google's legacy consent page, which a web client is
 *    routed to; nothing on this path goes near it.
 *  * `requestOfflineAccess(WEB_CLIENT_ID, true)` names the **web** client on
 *    purpose. A `drive.file` grant belongs to a user *and a client*, and the
 *    television reads with a token minted from the web client's secret, so a
 *    pick recorded against this app's Android client would grant the
 *    television nothing. The `true` forces a code that exchanges into a
 *    *refresh* token: without it only the first grant ever yields one, and
 *    every later pairing would hand over an access token that dies within
 *    the hour.
 *
 * The Android OAuth client is never named here. On Android an app is
 * identified to Google by its package name and signing certificate, so the
 * client exists in the console to make that pair recognisable and is
 * referenced by nothing in this file.
 *
 * **No credential is logged.** The server auth code crosses this class in
 * one value and goes straight to Dart, which carries it to the pairing
 * service. It is in no log line, no exception message and no error detail.
 */
class DrivePicker(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL)

    /** The `pick` whose picker is on screen; at most one at a time. */
    private var pending: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler(this)
    }

    /** Lets go of both halves; the activity is going away. */
    fun detach() {
        channel.setMethodCallHandler(null)
        pending = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "available" -> result.success(playServicesReady())
            "pick" -> {
                if (!playServicesReady()) {
                    result.error("unavailable", "Google Play services is not available.", null)
                    return
                }
                if (pending != null) {
                    result.error("busy", "A pick is already on screen.", null)
                    return
                }
                try {
                    start(result)
                } catch (error: Throwable) {
                    result.error("pick_failed", describe(error), null)
                }
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Whether this device can run the picker at all.
     *
     * Asked before anything is shown, because the honest answer on a device
     * without Play services is "use the web page", and finding that out from
     * a failed authorize would mean showing the viewer an error first.
     */
    private fun playServicesReady(): Boolean =
        GoogleApiAvailability.getInstance()
            .isGooglePlayServicesAvailable(activity) == ConnectionResult.SUCCESS

    private fun start(result: MethodChannel.Result) {
        val request = AuthorizationRequest.builder()
            .setRequestedScopes(listOf(com.google.android.gms.common.api.Scope(DRIVE_FILE_SCOPE)))
            // Only `drive.file` comes back, whatever else this account has
            // granted this client in the past.
            .setOptOutIncludingGrantedScopes(true)
            .setPrompt(
                AuthorizationRequest.Prompt.CONSENT or
                    AuthorizationRequest.Prompt.SELECT_ACCOUNT,
            )
            .addResourceParameter(
                AuthorizationRequest.ResourceParameter.PICKER_OAUTH_TRIGGER,
                "true",
            )
            .addResourceParameter(
                AuthorizationRequest.ResourceParameter.PICKER_ALLOW_MULTIPLE,
                "true",
            )
            .requestOfflineAccess(WEB_CLIENT_ID, true)
            .build()

        pending = result
        Identity.getAuthorizationClient(activity)
            .authorize(request)
            .addOnSuccessListener { authorization ->
                if (!authorization.hasResolution()) {
                    // Nothing to show: this account has already granted
                    // everything asked for, which means no picker ran and
                    // nothing was chosen.
                    finish { it.success(answerOf(authorization)) }
                    return@addOnSuccessListener
                }
                val sender = authorization.pendingIntent?.intentSender
                if (sender == null) {
                    finish { it.error("pick_failed", "No picker to show.", null) }
                    return@addOnSuccessListener
                }
                try {
                    activity.startIntentSenderForResult(sender, REQUEST_PICK, null, 0, 0, 0)
                } catch (error: Throwable) {
                    finish { it.error("pick_failed", describe(error), null) }
                }
            }
            .addOnFailureListener { error ->
                finish { it.error("pick_failed", describe(error), null) }
            }
    }

    /**
     * The picker closed. Returns whether this was ours, so the activity can
     * pass on anything that was not.
     */
    fun onActivityResult(requestCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK) return false
        if (pending == null) return true
        try {
            val authorization =
                Identity.getAuthorizationClient(activity).getAuthorizationResultFromIntent(data)
            finish { it.success(answerOf(authorization)) }
        } catch (error: Throwable) {
            // A viewer who pressed Back arrives here too. Dart reads an empty
            // answer as "cancelled", which is what it is, so this stays an
            // error only when something was genuinely wrong — and Dart treats
            // a code-less answer as cancelled either way.
            finish { it.error("pick_failed", describe(error), null) }
        }
        return true
    }

    private fun finish(answer: (MethodChannel.Result) -> Unit) {
        val result = pending ?: return
        pending = null
        answer(result)
    }

    /**
     * What Dart is given: the ids, and the code that turns into the
     * television's credential. Nothing else, and nothing about the access
     * token — the television mints its own.
     *
     * `picked_file_ids` is produced by Play services at runtime and appears
     * nowhere in the client library, which is why it is read by name out of
     * a Bundle rather than off a typed field.
     */
    private fun answerOf(authorization: AuthorizationResult): Map<String, Any?> {
        val params: Bundle? = authorization.tokenResponseParams
        val ids = params?.getString(PICKED_FILE_IDS)
            ?.split(",")
            ?.map { it.trim() }
            ?.filter { it.isNotEmpty() }
            .orEmpty()
        return mapOf(
            "serverAuthCode" to authorization.serverAuthCode,
            "fileIds" to ids,
        )
    }

    /** An exception as a sentence, naming no value it carried. */
    private fun describe(error: Throwable): String =
        "${error.javaClass.simpleName}: ${error.message ?: "no message"}"

    private companion object {
        const val CHANNEL = "xtremio/drive_picker"
        const val REQUEST_PICK = 0x0D21
        const val DRIVE_FILE_SCOPE = "https://www.googleapis.com/auth/drive.file"
        const val PICKED_FILE_IDS = "picked_file_ids"

        /**
         * The **web** client, whose secret the pairing service holds. See the
         * class comment for why this and not the Android one; it is a public
         * identifier and carries no secret.
         */
        const val WEB_CLIENT_ID =
            "55893685423-gv2bba8akveimtbepg2ot7iohm3g64pp.apps.googleusercontent.com"
    }
}
