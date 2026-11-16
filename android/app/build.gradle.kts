import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

// Flutter passes the Dart entry point as the `target` property (default
// lib/main.dart, relative to the Flutter project). Only the application's own
// entry points under lib/ build as the production package. Every other target,
// including integration tests and the temporary listener `flutter test`
// generates for them, installs under a separate application ID, so a test run
// can never replace, uninstall or write into the production installation.
val integrationTestApplicationIdSuffix = ".integrationtest"
val flutterProjectDir: File = rootProject.projectDir.parentFile
val dartEntryPoint: File = ((findProperty("target") as String?) ?: "lib/main.dart")
    .let { File(it).takeIf(File::isAbsolute) ?: flutterProjectDir.resolve(it) }
    .canonicalFile
val isApplicationEntryPoint =
    dartEntryPoint.startsWith(flutterProjectDir.resolve("lib").canonicalFile)

android {
    namespace = "dev.axiotask.axiotask"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.axiotask.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        if (!isApplicationEntryPoint) {
            applicationIdSuffix = integrationTestApplicationIdSuffix
        }
    }
    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                fun required(key: String): String = keystoreProperties.getProperty(key)
                    ?: throw GradleException("Missing release signing property: $key")
                storeFile = rootProject.file(required("storeFile"))
                storePassword = required("storePassword")
                keyAlias = required("keyAlias")
                keyPassword = required("keyPassword")
            }
        }
    }
    buildTypes {
        release {
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
