# google_mlkit_text_recognition declares the non-Latin script models as compileOnly; MoMa only uses Latin.
# Without these, R8 fails the release build with "Missing classes detected".
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
