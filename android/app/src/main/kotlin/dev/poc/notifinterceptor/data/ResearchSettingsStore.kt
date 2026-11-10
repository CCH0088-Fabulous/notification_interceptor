package dev.poc.notifinterceptor.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import dev.poc.notifinterceptor.domain.ResearchPolicy
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Files and keys never participate in Android Auto Backup. Plain token stays native. */
class ResearchSettingsStore(context: Context) {
    private val file = AtomicFile(File(context.noBackupFilesDir, "research-settings.json"))
    private val alias = context.packageName + ".research-upload-token"

    fun load(defaultCohort: String): ResearchSettings {
        if (!file.baseFile.exists()) return ResearchSettings(cohort = defaultCohort)
        val map = Json.parseObject(file.openRead().use { it.readBytes().toString(Charsets.UTF_8) })
            ?: throw IllegalStateException("研究设置损坏，请退出并清除本机研究数据后重新配置")
        require(map["schemaVersion"] == 1) { "不支持的研究设置版本" }
        val accepted = (map["acceptedDisclosureVersion"] as? Number)?.toInt()
            ?: (map["disclosureVersion"] as? Number)?.toInt() ?: 0
        require(accepted in 0..ResearchPolicy.DISCLOSURE_VERSION) { "不支持的研究说明版本" }
        val wasEnabled = map["enabled"] as? Boolean ?: false
        val outdated = wasEnabled && accepted < ResearchPolicy.DISCLOSURE_VERSION
        return ResearchSettings(
            enabled = wasEnabled && !outdated,
            ruleStructures = map["ruleStructures"] as? Boolean ?: false,
            autoUpload = map["autoUpload"] as? Boolean ?: false,
            wifiOnly = map["wifiOnly"] as? Boolean ?: true,
            cohort = (map["cohort"] as? String).orEmpty().ifEmpty { defaultCohort },
            endpoint = (map["endpoint"] as? String).orEmpty(),
            token = (map["encryptedToken"] as? String)?.takeIf { it.isNotEmpty() }?.let(::decrypt).orEmpty(),
            participantId = (map["participantId"] as? String).orEmpty(),
            consentAt = (map["consentAt"] as? Number)?.toLong() ?: 0,
            revision = (map["revision"] as? Number)?.toLong() ?: 0,
            pilotPending = map["pilotPending"] as? Boolean ?: false,
            pilotEnrolled = map["pilotEnrolled"] as? Boolean ?: false,
            endedAt = (map["endedAt"] as? Number)?.toLong()?.takeIf { it > 0 }
                ?: if (outdated) System.currentTimeMillis() else 0,
            acceptedDisclosureVersion = accepted,
        ).also {
            require(!it.enabled || (it.participantId.isNotBlank() && it.consentAt > 0)) { "研究同意记录损坏" }
            if (outdated) save(it)
        }
    }

    fun save(settings: ResearchSettings) {
        val map = settings.publicMap().toMutableMap<String, Any>()
        map.remove("hasToken")
        map["schemaVersion"] = 1
        map["encryptedToken"] = if (settings.token.isEmpty()) "" else encrypt(settings.token)
        val stream = file.startWrite()
        try {
            stream.write(Json.stringify(map).toByteArray(Charsets.UTF_8))
            file.finishWrite(stream)
        } catch (error: Throwable) {
            file.failWrite(stream)
            throw error
        }
    }

    fun delete() { file.delete() }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }

    private fun encrypt(text: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        return Base64.encodeToString(cipher.iv + cipher.doFinal(text.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
    }

    private fun decrypt(text: String): String {
        val bytes = Base64.decode(text, Base64.NO_WRAP)
        require(bytes.size > 28) { "研究令牌损坏" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        }
        return cipher.doFinal(bytes.copyOfRange(12, bytes.size)).toString(Charsets.UTF_8)
    }
}
