# UniFFI's Android bindings call JNA through reflection and native method
# registration. Keep the JNA object model intact; in particular Pointer.peer
# is looked up by the JNA runtime and must not be renamed or removed by R8.
-keep class com.sun.jna.** { *; }
-keep class com.enigmadux.knotq.ffi.** { *; }
-dontwarn java.awt.**
-keepclasseswithmembers,includedescriptorclasses class * {
    native <methods>;
}
