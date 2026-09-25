import groovy.json.JsonSlurper
import java.util.Properties

/**
 * The release signing key, or null on a machine that has not got it.
 *
 * `android/key.properties` and the keystore beside it are **not in the
 * repository** and never can be (`android/.gitignore`), so every build has to
 * cope with their absence: a fresh clone, a contributor, and CI before its
 * secret is unpacked. Absent, the release build falls back to the debug key
 * exactly as it did before there was a release key at all -- so `flutter build
 * apk --release` keeps working for anybody, and only a build that *has* the
 * key produces an APK that can update an installed one.
 *
 * What makes that safe rather than sloppy is that the two are told apart
 * afterwards: a release signed with the debug key has a different certificate,
 * so Android itself refuses to install it over a properly signed one. The
 * failure is loud and at install time, not silent and in the store.
 */
val releaseSigning: Properties? by lazy {
    val file = rootProject.file("key.properties")
    if (!file.exists()) {
        null
    } else {
        Properties().apply { file.inputStream().use { load(it) } }
    }
}

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
    // CastDevice, and the MediaRouter route it rides on: where a receiver's
    // own IP is, which MainActivity.castDeviceAddress reads off the route
    // the Cast SDK discovered. flutter_chrome_cast's
    // play-services-cast-framework:21.5.0 already resolves exactly this
    // (mediarouter with it), but as `implementation` of its own module, so
    // naming it here adds nothing to the APK -- it only reaches our own
    // compile classpath.
    implementation("com.google.android.gms:play-services-cast:21.5.0")
    // Google Identity Services, for the *native* Drive picker
    // (DrivePicker.kt). The web Google Picker cannot select more than one
    // file on a phone -- it gates selection on a Ctrl/Cmd key
    // (issuetracker.google.com/issues/334994030) -- and this one can.
    // `AuthorizationRequest.ResourceParameter`, which is what carries the
    // picker trigger, exists from 21.6.0 onward, so that is the floor.
    implementation("com.google.android.gms:play-services-auth:22.0.0")
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

    signingConfigs {
        // Declared only when the key is actually here: an empty signing config
        // is worse than none, because Gradle would accept it and fail late
        // with a message about a missing store file rather than about a
        // missing key.
        releaseSigning?.let { key ->
            create("release") {
                storeFile = rootProject.file(key.getProperty("storeFile"))
                storePassword = key.getProperty("storePassword")
                keyAlias = key.getProperty("keyAlias")
                keyPassword = key.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // The release key when this machine has it, the debug key when it
            // has not -- see [releaseSigning]. This is the whole of what used
            // to be a TODO, and the reason it mattered: an app's identity *is*
            // its signing certificate, so App Links, an Android OAuth client
            // and every future update are all keyed on this and on nothing
            // else.
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
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
