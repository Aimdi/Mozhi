# R8 rules for release builds (minifyEnabled). The Flutter Gradle plugin and
# most plugins ship their own consumer rules; these are a safety net.

# Flutter embedding and generated plugin registrant.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }

# The app's activity (platform channels for shared/selected text).
-keep class io.github.aimdi.mozhi.** { *; }

# Deferred components (Play Core) are referenced by the embedding but unused.
-dontwarn com.google.android.play.core.**

# Keep annotations and generic signatures used by plugins (reflection).
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod
