import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing (#300). The keystore and its passwords live in
// android/key.properties, which is GITIGNORED and never leaves the machine that
// holds the key; the release workflow writes it from repository secrets.
//
//     storeFile=/absolute/or/android-relative/path/axiotask-release.jks
//     storePassword=...
//     keyAlias=axiotask
//     keyPassword=...
//
// Without that file the release build falls back to the throwaway debug key, so
// `flutter run --release` keeps working on a fresh clone — but that fallback is
// announced loudly, because a debug-signed "release" APK looks perfectly normal
// right up to the moment someone tries to sign in: Play Services authorization
// identifies the app by package name + signing-certificate SHA-1 (RFC-010), and
// the debug certificate is not the one registered with the Google Cloud project.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "com.axiotask.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.axiotask.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            // A half-written key.properties (a secret that did not reach the
            // workflow, a typo'd key) would otherwise fail as a null cast deep
            // inside Gradle. Say which line is missing instead.
            fun required(key: String): String = keystoreProperties[key] as String?
                ?: throw GradleException(
                    "android/key.properties has no `$key` — the release signing " +
                        "configuration needs storeFile, storePassword, keyAlias " +
                        "and keyPassword."
                )
            create("release") {
                // A relative storeFile resolves against android/, next to
                // key.properties itself; an absolute path (what the release
                // workflow writes) is used as given.
                storeFile = rootProject.file(required("storeFile"))
                storePassword = required("storePassword")
                keyAlias = required("keyAlias")
                keyPassword = required("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

if (!hasReleaseKeystore) {
    // logger.error, not lifecycle: Gradle sends error-level output to stderr,
    // which is the only channel `flutter build apk` shows without -v. A warning
    // nobody sees is how a debug-signed APK gets published.
    logger.error(
        "axiotask: no android/key.properties — release builds are signed with the " +
            "DEBUG key. Such an APK installs and runs, but Google sign-in will fail: " +
            "Play Services authorizes the app by package name + signing certificate " +
            "SHA-1, and the debug certificate is not the registered one. Fine for " +
            "`flutter run --release`; never publish it."
    )
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
