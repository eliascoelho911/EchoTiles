import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val signingPropertiesPath = providers.environmentVariable("ECHOTILES_KEY_PROPERTIES")
    .orNull?.takeIf { it.isNotBlank() }
val keystorePropertiesFile = rootProject.file(signingPropertiesPath ?: "key.properties")
val hasReleaseKeystore = keystorePropertiesFile.isFile
if (signingPropertiesPath != null || keystorePropertiesFile.exists()) {
    require(hasReleaseKeystore) { "Arquivo privado de assinatura não encontrado ou inválido." }
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
    for (propertyName in listOf("keyAlias", "keyPassword", "storeFile", "storePassword")) {
        require(!keystoreProperties.getProperty(propertyName).isNullOrBlank()) {
            "Configuração privada de assinatura incompleta: falta $propertyName."
        }
    }
    require(file(keystoreProperties.getProperty("storeFile")).isFile) {
        "Keystore configurada não encontrada."
    }
} else {
    logger.warn("EchoTiles YouTube: release de protótipo com assinatura debug local; não usar para distribuição.")
}

android {
    namespace = "com.sidhant.echotiles"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }


    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }

    defaultConfig {
        applicationId = "com.sidhant.echotiles.youtubeprototype"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (hasReleaseKeystore) "release" else "debug")
        }
    }

    applicationVariants.all {
        val variant = this
        variant.outputs.all {
            val output = this as com.android.build.gradle.internal.api.ApkVariantOutputImpl
            val abiCodes = mapOf("armeabi-v7a" to 1, "arm64-v8a" to 2, "x86_64" to 3)
            val abiName = output.getFilter(com.android.build.OutputFile.ABI)
            val abiCode = abiCodes[abiName]
            if (abiCode != null) {
                output.versionCodeOverride = (variant.versionCode) * 10 + abiCode
            }
        }
    }

    packagingOptions {
        dex.useLegacyPackaging = true
        jniLibs.useLegacyPackaging = true
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
