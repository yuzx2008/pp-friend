import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 正式签名的 keystore 路径与口令，从 `android/key.properties` 读（**不在仓库里**，
// `.gitignore` 挡着）。文件由构建脚本从仓库外一份 600 的文件拷进来；上游 CI 和
// 本地 `flutter run` 都没有这个文件，那就走下面的回落。
//
// 为什么必须固定一个签名：原来 release 借用 debug keystore，而那份 keystore
// 是在构建容器的 `$HOME` 里**现生成**的 —— 每次构建都是一个新密钥，于是包与包
// 之间**装不上**（Android 只认同一个签名证书的升级，签名不一致只能先卸载，
// 用户数据一起没）。
val keyPropertiesFile = rootProject.file("key.properties")
val keyProperties = Properties()
if (keyPropertiesFile.exists()) {
    FileInputStream(keyPropertiesFile).use { keyProperties.load(it) }
}

android {
    namespace = "com.ppfriend.pp_friend"
    compileSdk = flutter.compileSdkVersion
    // 钉死而不是跟着 flutter.ndkVersion 走：tools/build_rust_android.sh 用这个
    // 版本的 libc++_shared.so，两边一旦漂移，构建期和运行期的 C++ 运行库就会
    // 悄悄错开 —— 那种崩溃报错信息离现场很远，很难查。
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.ppfriend.pp_friend"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // 写死 29（Android 10），不用 flutter.minSdkVersion（那是 24）。
        // 原因：上行音频是 Ogg Opus，而 Opus **编码器**和 MUXER_OUTPUT_OGG
        // 都要 API 29。24~28 没有编码器，只能发 WAV —— 但服务端规范只收
        // audio/ogg，发过去必然失败。与其留一个"看起来成功实际失败"的回落，
        // 不如把门槛提到 29。
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 只出 arm64-v8a。理由有两层：
        //  1. 我们只有这一个 ABI 的 .so —— 别的 ABI 上 librust_lib_pp_friend.so
        //     不存在，dlopen 会失败（会走到主界面的红色横幅，但那是白装一次）。
        //  2. 那个 .so 有 22MB（静态链了 ONNX Runtime 和 Silero 模型），
        //     出多个 ABI 会让 APK 白白胖三倍。
        //
        // **必须先 clear**：flutter-gradle-plugin 在它自己的 apply() 里已经塞进了
        // PLATFORM_ABI_LIST（arm/arm64/x64），而 apply() 在 plugins{} 那一刻就跑完了，
        // 早于本文件的 android{} 块。不 clear 只 += 的话等于什么都没做 ——
        // 这一点是实测出来的，不是推的。
        ndk {
            abiFilters.clear()
            abiFilters += "arm64-v8a"
        }
    }

    // **有 key.properties 才建这个签名配置。** 没有它 `signingConfigs.getByName("release")`
    // 会直接抛，仓库一到别人的 CI 上就构建不了 —— 上游 CI 出的包一直是 debug
    // 签名的，不能因为我们本地要正式签名就把那条路弄坏。
    signingConfigs {
        if (keyPropertiesFile.exists()) {
            create("release") {
                storeFile = file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // 没有正式密钥就照旧借 debug 签名，`flutter run --release` 还能用。
            signingConfig = if (keyPropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }

            // **必须显式关掉：release 走 R8 会把这个包装不起来。**
            // AGP 9 起 release 默认 minifyEnabled=true、shrinkResources=true
            // （本文件里没写过任何 minify/proguard 配置，仓库里也没有 proguard
            // 文件，所以这是默认值不是我们要求的效果）。而 R8 会重命名类型：
            // build/outputs/mapping/release/mapping.txt 里就有
            // `kotlin.coroutines.Continuation -> i5`。
            //
            // 麻烦在于 shared_preferences_android 2.5 起改成了 JNIgen —— Dart 侧
            // 是拿**未混淆的类名 + 方法签名**直接经 JNI 调 Kotlin 的
            // （SharedPreferencesApiRegistrar.getAll(String, List, Continuation)）。
            // 签名里的 Continuation 一改名，运行时按原名就找不到方法：
            // NoSuchMethodError → 配置读写全挂 → 档案列表为空 → 配置页白屏。
            //
            // 选"关掉"而不是"补 keep 规则"：签名里任何一个类型被改名都会重演，
            // 而 keep 规则得把每个 JNIgen 插件用到的类、方法、以及 Coroutine 那套
            // 运行时类型全钉住，补不全就还是白屏；这个方法名和签名是 Dart 侧硬编码
            // 的，改错了要到运行期才会发现。
            isMinifyEnabled = false
            isShrinkResources = false
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
