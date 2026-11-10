package dev.poc.notifinterceptor.bridge

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/** User chooses the recipient. Returning from Sharesheet is not a delivery receipt. */
class ResearchArchivePicker(private val activity: Activity) {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var pending: Pair<File, MethodChannel.Result>? = null
    private var disposed = false

    fun share(file: File, result: MethodChannel.Result) {
        check(!disposed) { "页面已关闭，请重试" }
        val uri = FileProvider.getUriForFile(activity, activity.packageName + ".research.files", file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "application/zip"
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_SUBJECT, "内测数据")
            clipData = ClipData.newRawUri("内测数据", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        activity.startActivity(Intent.createChooser(intent, "分享内测数据"))
        result.success(true)
    }

    fun save(file: File, result: MethodChannel.Result) {
        check(!disposed && pending == null) { "请先完成当前文件保存" }
        pending = file to result
        try {
            activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "application/zip"
                putExtra(Intent.EXTRA_TITLE, file.name)
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            }, REQUEST)
        } catch (error: Exception) { pending = null; throw error }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST) return false
        val request = pending ?: return true
        pending = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { request.second.success(false); return true }
        worker.execute {
            val operation = runCatching {
                val stream = activity.contentResolver.openOutputStream(uri, "wt") ?: error("无法保存文件，请重试")
                stream.use { output -> request.first.inputStream().use { it.copyTo(output) } }
            }
            main.post {
                if (disposed) request.second.error("RESEARCH_FILE", "页面已关闭，原始数据仍保留", null)
                else operation.onSuccess { request.second.success(true) }
                    .onFailure { request.second.error("RESEARCH_FILE", "文件未能保存，原始数据仍保留，请重试", null) }
            }
        }
        return true
    }

    fun dispose() {
        disposed = true
        pending?.second?.error("RESEARCH_FILE", "页面已关闭，原始数据仍保留", null)
        pending = null
        worker.shutdown()
    }

    companion object { private const val REQUEST = 24763 }
}
