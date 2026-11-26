import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing material lives outside the repository (see docs/RELEASING.md). Never commit it.
val keyProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasReleaseKey = keyProperties.getProperty("storeFile") != null

android {
    namespace = "vn.moma.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "vn.moma.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Both come from `version:` in pubspec.yaml (MAJOR.MINOR.PATCH+BUILD).
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            // Lets a debug build be installed next to the release build.
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
        release {
            // No silent fallback to debug keys: a release build without a real key must fail.
            signingConfig = if (hasReleaseKey) signingConfigs.getByName("release") else null
        }
    }
}

// Fail fast when a release artifact is requested without a signing key.
gradle.taskGraph.whenReady {
    val wantsRelease = allTasks.any { it.name.contains("Release", ignoreCase = true) && it.name.startsWith("assemble") || it.name.startsWith("bundleRelease") }
    if (wantsRelease && !hasReleaseKey) {
        throw GradleException("Release build requires android/key.properties (see docs/RELEASING.md). Refusing to sign with debug keys.")
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
