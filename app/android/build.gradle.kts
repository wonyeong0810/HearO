allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// ---------------------------------------------------------------------------
// 플러그인 모듈의 JVM 타깃을 17 로 통일한다.
//
// 오래된 Flutter 플러그인 중에는 Java 8 / Kotlin 21 처럼 서로 어긋난 설정을
// 들고 오는 것들이 있다 (tflite_flutter, torch_light 등). 그러면
// "Inconsistent JVM-target compatibility" 로 빌드가 통째로 실패한다.
// 플러그인이 고쳐질 때까지 여기서 일괄로 맞춰 준다.
//
// ⚠️ 이 블록은 반드시 아래 evaluationDependsOn(":app") 보다 **먼저** 와야 한다.
//    그쪽이 서브프로젝트 평가를 강제하기 때문에, 순서가 뒤바뀌면
//    "Cannot run Project.afterEvaluate when the project is already evaluated"
//    로 빌드가 죽는다.
// ---------------------------------------------------------------------------
// 플러그인 모듈이 컴파일할 Android API 레벨. app 모듈의 compileSdk 와 맞춘다.
// 최신 androidx 라이브러리들이 34 이상을 요구하는데, 구형 플러그인은 33 에
// 묶여 있어 "requires libraries ... to compile against version 34 or later" 로
// 빌드가 깨진다.
val pluginCompileSdk = 36

subprojects {
    afterEvaluate {
        extensions.findByName("android")?.let { android ->
            if (android is com.android.build.gradle.BaseExtension) {
                android.compileSdkVersion(pluginCompileSdk)
                android.compileOptions {
                    sourceCompatibility = JavaVersion.VERSION_17
                    targetCompatibility = JavaVersion.VERSION_17
                }
            }
        }
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions {
                jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
