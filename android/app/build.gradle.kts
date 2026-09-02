import groovy.json.JsonSlurper

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// rustls-platform-verifier is a Rust crate with a Kotlin component (an AAR
// shipped inside the crate, not on Maven). Locate it through cargo so the
// Kotlin side always matches the Rust version in rust/Cargo.lock.
fun RepositoryHandler.rustlsPlatformVerifier(): MavenArtifactRepository {
    val metadataJson =
        providers.exec {
            workingDir = file("../../rust")
            commandLine(
                "cargo", "metadata", "--format-version", "1", "--locked",
                "--filter-platform", "aarch64-linux-android",
            )
        }.standardOutput.asText.get()

    @Suppress("UNCHECKED_CAST")
    val packages = (JsonSlurper().parseText(metadataJson) as Map<String, Any?>)["packages"] as List<Map<String, Any?>>
    val manifestPath =
        packages.first { it["name"] == "rustls-platform-verifier-android" }["manifest_path"] as String
    return maven {
        url = uri(File(File(manifestPath).parentFile, "maven"))
        metadataSources { artifact() }
    }
}

repositories {
    rustlsPlatformVerifier()
}

dependencies {
    // Kotlin half of rustls-platform-verifier; the version tracks the crate.
    implementation("rustls:rustls-platform-verifier:latest.release")
}

android {
    namespace = "com.zond.xtremio"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.zond.xtremio"
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
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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
