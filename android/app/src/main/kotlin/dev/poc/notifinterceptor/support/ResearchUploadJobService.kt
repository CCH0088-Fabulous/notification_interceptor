package dev.poc.notifinterceptor.support

import android.app.job.JobParameters
import android.app.job.JobService
import android.os.Handler
import android.os.Looper
import java.util.concurrent.Executors
import java.util.concurrent.Future

class ResearchUploadJobService : JobService() {
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var running: JobParameters? = null
    private var task: Future<*>? = null

    override fun onStartJob(params: JobParameters): Boolean {
        running = params
        task = executor.submit {
            val retry = runCatching { AppGraph.ensure(applicationContext).research.sync(manual = false)["retry"] == true }.getOrDefault(true)
            main.post {
                if (running === params) { running = null; jobFinished(params, retry) }
            }
        }
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        running = null
        task?.cancel(true)
        AppGraph.ensure(applicationContext).research.cancelUpload()
        return true
    }

    override fun onDestroy() { task?.cancel(true); executor.shutdownNow(); super.onDestroy() }
}
