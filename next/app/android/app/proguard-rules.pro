# JNA's native bootstrap looks up these classes, methods, and fields by their
# original JVM names. R8 renaming com.sun.jna.Pointer.peer breaks Iroh startup
# in release APKs with "Can't obtain peer field ID for class com.sun.jna.Pointer".
-keep class com.sun.jna.** { *; }
-keep class * extends com.sun.jna.Structure { *; }
-keep class * implements com.sun.jna.Library { *; }
-keepclassmembers class * {
    native <methods>;
}
-dontwarn com.sun.jna.**

# computer.iroh is a UniFFI/JNA binding over libiroh_ffi.so. Keep the generated
# FFI wrapper names stable because the native side and JNA callbacks cross the
# JVM boundary by name and structure shape.
-keep class computer.iroh.** { *; }
-dontwarn computer.iroh.**
