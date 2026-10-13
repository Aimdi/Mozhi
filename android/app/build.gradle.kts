import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing, in order of preference:
//  1. Environment (CI): ANDROID_KEYSTORE_PATH, ANDROID_KEYSTORE_PASSWORD,
//     ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD.
//  2. android/key.properties: storeFile, storePassword, keyAlias, keyPassword.
//  3. Otherwise release builds are signed with the debug key so that
//     `flutter build apk --release` works out of the box (local builds, forks,
//     pull requests). Such APKs cannot update a properly signed install.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

fun env(name: String): String? = System.getenv(name)?.takeIf { it.isNotBlank() }

val useEnvSigning = env("ANDROID_KEYSTORE_PATH") != null
val releaseStoreFile = (
    env("ANDROID_KEYSTORE_PATH")
        ?: keystoreProperties.getProperty("storeFile")?.takeIf { it.isNotBlank() }
)?.let { file(it) }
val releaseStorePassword: String? =
    if (useEnvSigning) env("ANDROID_KEYSTORE_PASSWORD")
    else keystoreProperties.getProperty("storePassword")
val releaseKeyAlias: String? =
    if (useEnvSigning) env("ANDROID_KEY_ALIAS") ?: env("ANDROID_KEYSTORE_ALIAS")
    else keystoreProperties.getProperty("keyAlias")
val releaseKeyPassword: String? =
    if (useEnvSigning) {
        env("ANDROID_KEY_PASSWORD")
            ?: env("ANDROID_KEYSTORE_PRIVATE_KEY_PASSWORD")
            ?: env("ANDROID_KEYSTORE_PASSWORD")
    } else {
        keystoreProperties.getProperty("keyPassword")
    }
val hasReleaseKeystore = releaseStoreFile != null

android {
    namespace = "io.github.aimdi.mozhi"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.aimdi.mozhi"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version from pubspec.yaml. Split-per-ABI builds add
        // 1000 * ABI_VERSION to the version code automatically.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseStoreFile != null) {
            create("release") {
                storeFile = releaseStoreFile
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    flavorDimensions += "default"
    productFlavors {
        create("production") {
            dimension = "default"
            applicationIdSuffix = ""
            manifestPlaceholders["appName"] = "Mozhi"
        }
        create("staging") {
            dimension = "default"
            applicationIdSuffix = ".stg"
            manifestPlaceholders["appName"] = "[STG] Mozhi"
        }
        create("development") {
            dimension = "default"
            applicationIdSuffix = ".dev"
            manifestPlaceholders["appName"] = "[DEV] Mozhi"
        }
    }

    buildTypes {
        getByName("release") {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        getByName("debug") {
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

dependencies {
    implementation("org.jetbrains.kotlin:kotlin-stdlib:2.2.10")
}
