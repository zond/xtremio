import groovy.json.JsonSlurper

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// rustls-platform-verifier is a Rust crate with a Kotlin component (an AAR
// shipped inside the crate, not on Maven). Locate it through cargo so the
// Kotlin side always matches the Rust version in rust/Cargo.lock. The crate's
// tiny repo has no maven-metadata.xml, so a dynamic version such as
// `latest.release` cannot be resolved; pin the exact version cargo reports.
val rustlsPlatformVerifierAndroid: Pair<File, String> by lazy {
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
    val pkg = packages.first { it["name"] == "rustls-platform-verifier-android" }
    val repo = File(File(pkg["manifest_path"] as String).parentFile, "maven")
    repo to (pkg["version"] as String)
}

repositories {
    maven {
        url = uri(rustlsPlatformVerifierAndroid.first)
        content { includeModule("rustls", "rustls-platform-verifier") }
    }
}

dependencies {
    // Kotlin half of rustls-platform-verifier; the version tracks the crate.
    implementation("rustls:rustls-platform-verifier:${rustlsPlatformVerifierAndroid.second}")
    // NotificationCompat and the permission/foreground-service helpers the
    // downloads service is built on. The Flutter embedding pulls androidx
    // core in transitively, but transitively is not on our compile
    // classpath, so it is asked for by name.
    implementation("androidx.core:core-ktx:1.17.0")
    // Plain JVM tests, for the Kotlin that has no Android in it.
    testImplementation("junit:junit:4.13.2")
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

        // Prune plugins' prebuilt native libraries down to the ABI(s) this
        // build actually targets. `--target-platform` only controls what
        // *Flutter itself* compiles and copies in (libapp.so, libflutter.so,
        // libxtremio_core.so via cargokit) -- it never reaches the merged
        // jniLibs from a plugin's AAR. media_kit_libs_android_video, for
        // one, ships prebuilt libmpv/libdartjni/libmediakitandroidhelper for
        // every ABI in its AAR regardless, and only `ndk.abiFilters` (an AGP
        // packaging filter, not a Flutter one) prunes those. The Flutter
        // Gradle plugin does set a default itself (`FlutterPlugin.
        // configureAbiWithoutSplits`), but always to *all three* ABIs it
        // supports -- that default exists only to keep 32-bit x86 out for
        // Google Play, not to track what `--target-platform` actually asked
        // for -- so without this, a single-ABI build still ships every
        // plugin's libraries for the other two. Re-derive the filter from
        // the same `-Ptarget-platform` Gradle property Flutter's own plugin
        // reads (`FlutterPluginUtils.PROP_TARGET_PLATFORM`), so this follows
        // whatever `flutter build apk` was told to build: a plain
        // `flutter build apk` (no target-platform passed) leaves Flutter's
        // own default -- all three ABIs -- untouched, and `--split-per-abi`
        // is left alone too, since AGP's ABI splits already produce one
        // single-ABI APK per split and don't need this override to do it.
        val targetPlatformProperty = project.findProperty("target-platform") as String?
        val isSplitPerAbi = (project.findProperty("split-per-abi") as String?)?.toBoolean() ?: false
        val abiFilteringDisabled = (project.findProperty("disable-abi-filtering") as String?)?.toBoolean() ?: false
        if (targetPlatformProperty != null && !isSplitPerAbi && !abiFilteringDisabled) {
            val requestedAbis =
                targetPlatformProperty.split(",").map { platform ->
                    when (platform) {
                        "android-arm" -> "armeabi-v7a"
                        "android-arm64" -> "arm64-v8a"
                        "android-x64" -> "x86_64"
                        else -> throw GradleException("Unknown Flutter target-platform: $platform")
                    }
                }
            ndk {
                abiFilters.clear()
                abiFilters.addAll(requestedAbis)
            }
        }
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
