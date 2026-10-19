plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Opt-in fictional runtime harnesses; no normal application activation.
val journalValidation = providers.gradleProperty("journalValidation").orNull == "true"
val locationValidation = providers.gradleProperty("locationValidation").orNull == "true"
check(!(journalValidation && locationValidation))

android {
    namespace = "com.example.chantipoint"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.chantipoint"
        if (journalValidation) {
            applicationIdSuffix = ".journalvalidation"
            testInstrumentationRunner = "com.example.chantipoint.journal.JournalRuntimeInstrumentation"
        }
        if (locationValidation) {
            applicationIdSuffix = ".locationvalidation"
            testInstrumentationRunner = "com.example.chantipoint.location.ForegroundLocationInstrumentation"
        }
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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

// Existing cached AndroidX version; cancellable single-fix API, no tracking service.
dependencies { implementation("androidx.core:core:1.17.0") }
