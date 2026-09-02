# rustls-platform-verifier's Kotlin component is only reached through JNI, so
# R8 sees it as dead code. Keep it (rule from the crate's README).
-keep, includedescriptorclasses class org.rustls.platformverifier.** { *; }
