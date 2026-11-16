package cn.zhikaotong.zhikaotong

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterActivity() {
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey("zhikaotong-session", null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("zhikaotong-session", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        // Keep file/Keystore operations ordered while moving disk sync off the UI thread.
        val storageQueue = messenger.makeBackgroundTaskQueue(
            BinaryMessenger.TaskQueueOptions().setIsSerial(true)
        )
        MethodChannel(
            messenger,
            "cn.zhikaotong/storage",
            StandardMethodCodec.INSTANCE,
            storageQueue
        ).setMethodCallHandler { call, result ->
            // Result callbacks support this background thread; acknowledge only after completion.
            try {
                val args = call.arguments as? Map<*, *> ?: emptyMap<String, String>()
                val name = args["key"] as? String ?: "state"
                require(name.matches(Regex("[a-zA-Z0-9_-]{1,100}")))
                val file = AtomicFile(File(filesDir, "$name.json"))
                when (call.method) {
                    "read" -> result.success(if (file.baseFile.exists()) file.openRead().bufferedReader().use { it.readText() } else null)
                    "write" -> {
                        val out = file.startWrite()
                        try { out.write((args["value"] as String).toByteArray(Charsets.UTF_8)); file.finishWrite(out) }
                        catch (e: Exception) { file.failWrite(out); throw e }
                        result.success(null)
                    }
                    "delete" -> { file.delete(); result.success(null) }
                    "secureRead" -> {
                        val encoded = getSharedPreferences("session", MODE_PRIVATE).getString(name, null)
                        if (encoded == null) result.success(null) else {
                            val parts = encoded.split(":")
                            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)))
                            result.success(String(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)), Charsets.UTF_8))
                        }
                    }
                    "secureWrite" -> {
                        val value = args["value"] as? String
                        val editor = getSharedPreferences("session", MODE_PRIVATE).edit()
                        if (value == null) editor.remove(name) else {
                            val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
                            val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
                            editor.putString(name, Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(encrypted, Base64.NO_WRAP))
                        }
                        check(editor.commit()) { "Session storage failed" }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) { result.error("STORAGE_ERROR", "本地保存失败，请重试", null) }
        }
    }
}
