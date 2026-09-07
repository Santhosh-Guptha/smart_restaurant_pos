# Suppression rules for Google ML Kit Text Recognition optional language packs
-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions

# Flutter keep rules
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.**

# Hive — keep all generated TypeAdapters and Hive model annotations
-keep class com.hivedb.** { *; }
-keep @com.hivedb.** class * { *; }
-keepclassmembers class * {
    @com.hivedb.** *;
}

# Firebase
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.firebase.**
-dontwarn com.google.android.gms.**

# Google Sign-In
-keep class com.google.android.gms.auth.** { *; }

# flutter_image_compress
-keep class com.fluttercandies.** { *; }
-dontwarn com.fluttercandies.**

# ML Kit — keep vision models
-keep class com.google.mlkit.** { *; }
-dontwarn com.google.mlkit.**

# Gson / JSON (used by various plugins)
-keepattributes Signature
-keepattributes *Annotation*
-dontwarn sun.misc.**
