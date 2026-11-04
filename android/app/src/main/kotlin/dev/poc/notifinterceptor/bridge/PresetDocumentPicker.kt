package dev.poc.notifinterceptor.bridge

import android.app.Activity
import android.content.Intent
import android.os.Handler
import android.os.Looper
import dev.poc.notifinterceptor.data.PresetTransferContent
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** The selected document grant is used immediately and never retained. */
class PresetDocumentPicker(private val activity: Activity) {
    private class Pending(
        val requestCode: Int,
        val result: MethodChannel.Result,
        val bytes: ByteArray? = null,
        var working: Boolean = false,
    )

    private var pending: Pending? = null
    private val main = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor { work ->
        Thread(work, "preset-document-io").apply { isDaemon = true }
    }
    private var disposed = false

    fun importFile(result: MethodChannel.Result) {
        val request = begin(REQUEST_IMPORT, result)
        launch(request, Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf(
                "application/json", "text/json", "text/plain", "application/octet-stream",
            ))
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        })
    }

    fun exportFile(
        content: String,
        fileName: String?,
        result: MethodChannel.Result,
        maxBytes: Int = PresetTransferContent.MAX_BYTES,
    ) {
        val bytes = PresetTransferContent.encode(content, maxBytes)
        val name = fileName?.trim()?.takeIf { it.isNotEmpty() } ?: "notification-presets.json"
        require(name.length <= 120 && name.none { it == '/' || it == '\\' || it == '\u0000' }) {
            "导出文件名无效"
        }
        val request = begin(REQUEST_EXPORT, result, bytes)
        launch(request, Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/json"
            putExtra(Intent.EXTRA_TITLE, if (name.endsWith(".json", ignoreCase = true)) name else "$name.json")
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        })
    }

    private fun begin(code: Int, result: MethodChannel.Result, bytes: ByteArray? = null): Pending {
        check(!disposed) { "页面已关闭，请重新打开预设管理" }
        check(pending == null) { "请先完成当前文件选择" }
        return Pending(code, result, bytes).also { pending = it }
    }

    @Suppress("DEPRECATION")
    private fun launch(request: Pending, intent: Intent) {
        try {
            activity.startActivityForResult(intent, request.requestCode)
        } catch (error: Exception) {
            pending = null
            throw error
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_IMPORT && requestCode != REQUEST_EXPORT) return false
        val request = pending ?: return true
        if (request.requestCode != requestCode || request.working) return true
        if (resultCode != Activity.RESULT_OK) {
            pending = null
            request.result.success(if (requestCode == REQUEST_IMPORT) null else false)
            return true
        }
        val uri = data?.data
        if (uri == null) {
            pending = null
            request.result.error(ERROR_FILE, "未取得所选文件，请重试", null)
            return true
        }
        request.working = true
        executor.execute {
            val response = runCatching {
                if (requestCode == REQUEST_IMPORT) {
                    val stream = activity.contentResolver.openInputStream(uri)
                        ?: throw IllegalStateException("无法打开所选预设文件")
                    stream.use(PresetTransferContent::read)
                } else {
                    val stream = activity.contentResolver.openOutputStream(uri, "wt")
                        ?: throw IllegalStateException("无法写入所选文件")
                    stream.use { it.write(requireNotNull(request.bytes)) }
                    true
                }
            }
            main.post {
                if (pending !== request || disposed) return@post
                pending = null
                response.onSuccess { request.result.success(it) }.onFailure {
                    request.result.error(ERROR_FILE, it.message ?: "文件操作失败，请重试", null)
                }
            }
        }
        return true
    }

    fun dispose() {
        disposed = true
        val request = pending
        pending = null
        request?.result?.error(ERROR_FILE, "页面已关闭，文件操作已取消", null)
        executor.shutdownNow()
    }

    companion object {
        private const val REQUEST_IMPORT = 24761
        private const val REQUEST_EXPORT = 24762
        private const val ERROR_FILE = "PRESET_FILE"
    }
}
