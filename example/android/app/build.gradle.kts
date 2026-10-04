plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.workvault.work_vault_example"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.workvault.work_vault_example"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(flutter.minSdkVersion, 26)
        targetSdk = maxOf(flutter.targetSdkVersion, 35)
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["workVaultHostOwnsWorkManager"] = "false"
    }

    buildTypes {
        debug {
            // tool/production_rehearsal.dart sets this to rehearse hosts that own WorkManager.
            val hostApplication = when (providers.environmentVariable("WORK_VAULT_HOST_INIT").orNull) {
                "manual" -> "com.workvault.work_vault_example.ManualWorkManagerApplication"
                "provider" -> "com.workvault.work_vault_example.ProviderWorkManagerApplication"
                else -> null
            }
            if (hostApplication != null) {
                manifestPlaceholders["applicationName"] = hostApplication
                manifestPlaceholders["workVaultHostOwnsWorkManager"] = "true"
            }
        }
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    // sqlite3 native assets make AGP configure CMake. The SDK copy of CMake
    // 3.22.1 does not start on this machine (STATUS_DLL_NOT_FOUND). 4.1.2 does.
    externalNativeBuild {
        cmake {
            version = "4.1.2"
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

dependencies {
    debugImplementation("androidx.work:work-runtime-ktx:2.10.1")
}
