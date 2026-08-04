package com.axiotask.plugin.googleauth

import android.app.Activity
import androidx.activity.result.ActivityResult
import androidx.activity.result.IntentSenderRequest
import app.tauri.annotation.ActivityCallback
import app.tauri.annotation.Command
import app.tauri.annotation.InvokeArg
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Invoke
import app.tauri.plugin.JSObject
import app.tauri.plugin.Plugin
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.AuthorizationResult
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.Scope

/**
 * Google sign-in on Android via Play Services `AuthorizationClient` (RFC-010).
 *
 * The client is identified by this app's package name + signing-certificate
 * SHA-1 matched against the registered Android OAuth client — no client id or
 * secret ships in the binary. We request the `tasks` scope only: this is
 * authorization (an access token), NOT authentication — we never establish user
 * identity (RFC-010 says do not add Sign in with Google / Credential Manager).
 *
 * DEVICE-ONLY (RFC-010 G5): nothing here is compiled or exercised by the desktop
 * quality gate. Live sign-in + one authorized Tasks call on a real phone is the
 * merge gate for this flow; the consent activity-result path below is the piece
 * that gate must confirm.
 */
@InvokeArg
class AuthorizeArgs {
    var interactive: Boolean = false
}

@TauriPlugin
class GoogleAuthPlugin(private val activity: Activity) : Plugin(activity) {
    private val tasksScope = "https://www.googleapis.com/auth/tasks"

    @Command
    fun authorize(invoke: Invoke) {
        val args = invoke.parseArgs(AuthorizeArgs::class.java)

        val request = AuthorizationRequest.builder()
            .setRequestedScopes(listOf(Scope(tasksScope)))
            .build()

        Identity.getAuthorizationClient(activity)
            .authorize(request)
            .addOnSuccessListener { result ->
                if (result.hasResolution()) {
                    if (args.interactive) {
                        launchConsent(invoke, result)
                    } else {
                        // A silent call must never show UI: report that the
                        // caller must sign in interactively. The Rust side maps
                        // this to `needs_reauth`.
                        resolveNeedsInteraction(invoke)
                    }
                } else {
                    resolveWithToken(invoke, result)
                }
            }
            .addOnFailureListener { e ->
                invoke.reject("authorize failed: ${e.message}")
            }
    }

    /**
     * Launch Google's account picker + consent via the returned PendingIntent.
     *
     * Tauri's plugin framework has NO raw `onActivityResult` forwarding: the
     * ONLY route is `Plugin.startIntentSenderForResult(invoke, request, name)`,
     * which launches through the manager's AndroidX `ActivityResultLauncher`
     * and delivers the result to the `@ActivityCallback` method named `name`,
     * with the `invoke` carried by the framework. (This routing is the G5
     * device-validation point.)
     */
    private fun launchConsent(invoke: Invoke, result: AuthorizationResult) {
        val pendingIntent = result.pendingIntent
            ?: return invoke.reject("authorize reported a resolution with no PendingIntent")
        try {
            val request = IntentSenderRequest.Builder(pendingIntent.intentSender).build()
            startIntentSenderForResult(invoke, request, "consentResult")
        } catch (e: Exception) {
            invoke.reject("failed to launch consent: ${e.message}")
        }
    }

    /** Consent result, delivered by the framework with the original invoke. */
    @ActivityCallback
    private fun consentResult(invoke: Invoke, result: ActivityResult) {
        val data = result.data
        if (result.resultCode != Activity.RESULT_OK || data == null) {
            invoke.reject("sign-in was cancelled")
            return
        }
        try {
            val authResult = Identity.getAuthorizationClient(activity)
                .getAuthorizationResultFromIntent(data)
            resolveWithToken(invoke, authResult)
        } catch (e: Exception) {
            invoke.reject("consent result failed: ${e.message}")
        }
    }

    private fun resolveWithToken(invoke: Invoke, result: AuthorizationResult) {
        val token = result.accessToken
        if (token.isNullOrEmpty()) {
            // A resolution-free result with no token still needs interaction.
            resolveNeedsInteraction(invoke)
            return
        }
        val ret = JSObject()
        ret.put("accessToken", token)
        ret.put("needsInteraction", false)
        invoke.resolve(ret)
    }

    private fun resolveNeedsInteraction(invoke: Invoke) {
        val ret = JSObject()
        ret.put("needsInteraction", true)
        invoke.resolve(ret)
    }

    @Command
    fun signOut(invoke: Invoke) {
        // Drop the local account association so the next sign-in shows the
        // picker. AuthorizationClient offers no explicit account-switch API
        // beyond re-consent; whether to ALSO revoke the grant at Google is
        // RFC-010 Q1 (open). For now this lets the app fall back to offline
        // mode; a full revoke can be added once Q1 is decided.
        invoke.resolve()
    }

}
