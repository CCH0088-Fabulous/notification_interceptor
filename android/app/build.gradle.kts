import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val researchPilot = Properties().apply {
    val config = file("../../.local/research-pilot.properties")
    if (config.exists()) config.inputStream().use { load(it) }
}
val researchOnlineEnabled = researchPilot.getProperty("onlineEnabled", "false") == "true"
fun buildString(value: String) = "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r") + "\""

android {
    namespace = "dev.poc.notifinterceptor"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "dev.poc.notifinterceptor"
        // NotificationListenerService 的 requestRebind / getActiveNotifications 需要 API 24+，
        // 项目基线取 26（Android 8.0），与 PLAN.md 一致。
        minSdk = 26
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField("boolean", "RESEARCH_ONLINE_ENABLED", researchOnlineEnabled.toString())
        buildConfigField("String", "RESEARCH_PILOT_ENDPOINT", buildString(if (researchOnlineEnabled) researchPilot.getProperty("endpoint", "") else ""))
        buildConfigField("String", "RESEARCH_PILOT_KEY", buildString(if (researchOnlineEnabled) researchPilot.getProperty("enrollmentKey", "") else ""))
    }

    buildFeatures { buildConfig = true }

    testOptions {
        unitTests.isReturnDefaultValues = false
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
