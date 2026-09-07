package com.zond.xtremio

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * What sending bytes over this device's current connection costs the person
 * who pays for it, pushed on the `xtremio/network` **event** channel for as
 * long as Dart is subscribed (`lib/shell/network_cost.dart`).
 *
 * **A watch, not a question.** The one consumer decides whether the
 * embedded server may go on sharing a torrent after playback ends, and a
 * phone changes networks under that decision with nobody touching the app:
 * asked once when a film ended, "this is Wi-Fi" is still the answer being
 * acted on while the owner is on the train paying for every byte. So a
 * `ConnectivityManager.NetworkCallback` on the default network reports the
 * change as it happens, and it is registered for exactly as long as Dart is
 * listening -- which is the life of the app, and so the life of the sharing
 * it governs.
 *
 * **Only `NET_CAPABILITY_NOT_METERED` counts as free.** Android 11 added
 * `NET_CAPABILITY_TEMPORARILY_NOT_METERED` for a metered link a carrier has
 * opened up for a while, which is the right capability for a bounded
 * download to wait for and the wrong one for this: seeding has no end, and a
 * link that reverts to billed halfway through leaves the owner paying for
 * whatever is still in flight.
 *
 * **Everything that is not a clear "not metered" is metered**, including no
 * network at all and a `ConnectivityManager` this context cannot produce.
 * There is no third value on the wire, because a caller could do nothing
 * with one but assume the expensive case anyway.
 */
class NetworkCostWatcher(private val context: Context) : EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var callback: ConnectivityManager.NetworkCallback? = null

    /** The last reading pushed, so an unchanged one is not pushed again. */
    private var last: String? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        val manager = connectivity()
        if (manager == null) {
            emit(METERED)
            return
        }
        val watcher = object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(
                network: Network,
                capabilities: NetworkCapabilities,
            ) = emit(costOf(capabilities))

            // The default network went away. Nothing is being sent over it
            // either way, and what replaces it is not known yet, so the
            // reading goes to the safe one until a capability arrives.
            override fun onLost(network: Network) = emit(METERED)
        }
        try {
            manager.registerDefaultNetworkCallback(watcher)
            callback = watcher
        } catch (error: SecurityException) {
            // ACCESS_NETWORK_STATE missing from a build that stripped it.
            emit(METERED)
            return
        }
        // Registering reports the default network's capabilities right
        // away -- but only if there is a default network. A device with
        // nothing connected would otherwise never hear a first reading,
        // and the Dart side pushes nothing until it has one.
        emit(costOf(manager.getNetworkCapabilities(manager.activeNetwork)))
    }

    override fun onCancel(arguments: Any?) = detach()

    /** Lets the network go, whether Dart cancelled or the activity did. */
    fun detach() {
        callback?.let { registered ->
            // Never registered, or already unregistered: not an error worth
            // taking the activity's teardown down with.
            try {
                connectivity()?.unregisterNetworkCallback(registered)
            } catch (error: IllegalArgumentException) {
                // Nothing to unregister after all.
            }
        }
        callback = null
        sink = null
        last = null
    }

    /**
     * Pushes [cost] on the platform thread, which is where an
     * `EventSink` may be touched at all -- a `NetworkCallback` runs on a
     * thread of the system's choosing. An unchanged reading is dropped:
     * `onCapabilitiesChanged` fires for things this app does not care
     * about (signal strength, link speed, a validation result), and a
     * settings write is the other end of every one of these.
     */
    private fun emit(cost: String) {
        main.post {
            if (cost == last) return@post
            last = cost
            sink?.success(cost)
        }
    }

    private fun costOf(capabilities: NetworkCapabilities?): String =
        if (capabilities != null &&
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
        ) {
            UNMETERED
        } else {
            METERED
        }

    private fun connectivity(): ConnectivityManager? =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager

    companion object {
        /** The spellings `NetworkCost.parse` reads on the Dart side. */
        const val UNMETERED = "unmetered"
        const val METERED = "metered"
    }
}
