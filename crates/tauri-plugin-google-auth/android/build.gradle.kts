plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.axiotask.plugin.googleauth"
    compileSdk = 36

    defaultConfig {
        minSdk = 24

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
    kotlinOptions {
        jvmTarget = "1.8"
    }
}

dependencies {

    implementation("androidx.core:core-ktx:1.13.1")
    // RFC-010 Q2: pin play-services-auth. 21.2.0 provides Identity.getAuthorizationClient / AuthorizationClient.
    implementation("com.google.android.gms:play-services-auth:21.2.0")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.1.5")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.5.1")
    // The Tauri Android core library that provides Plugin, Invoke, @Command, etc.
    // Resolved from the tauri crate's bundled android project; the app's aggregate
    // gradle wiring (tauri.settings.gradle) provides `:tauri-android` on the classpath.
    implementation(project(":tauri-android"))
}
