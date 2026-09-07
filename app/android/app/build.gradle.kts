plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.hearo.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications 18.x 는 java.time 백포트를 요구한다.
        // 이게 없으면 알림 스케줄링에서 NoClassDefFoundError 가 난다.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.hearo.app"

        // minSdk 24 (Android 7.0).
        // 접근성 앱이라 구형 기기 지원 범위를 넓게 잡는다. 알림 채널(API 26+)과
        // 포그라운드 서비스 타입(API 34+)은 플러그인이 런타임에 분기 처리한다.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: 배포 전 실제 서명 키로 교체할 것.
            // android/key.properties 는 .gitignore 에 등록되어 있다.
            signingConfig = signingConfigs.getByName("debug")

            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
