# Add project specific ProGuard rules here.
# You can control the set of applied configuration files using the
# proguardFiles setting in build.gradle.
#
# For more details, see
#   http://developer.android.com/guide/developing/tools/proguard.html

# Keep the plugin class so Tauri can reflectively load it, and keep the
# Play Services auth classes used by the Google authorization flow.
-keep class com.axiotask.plugin.googleauth.** { *; }
-keep class com.google.android.gms.auth.** { *; }
