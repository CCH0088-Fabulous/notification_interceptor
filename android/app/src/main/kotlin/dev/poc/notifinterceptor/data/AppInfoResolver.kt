package dev.poc.notifinterceptor.data

import android.content.Context
import android.content.pm.PackageManager
import java.util.concurrent.ConcurrentHashMap

/** 包名 → 应用名，带缓存。避免请求 QUERY_ALL_PACKAGES 权限。 */
class AppInfoResolver(private val context: Context) {

    private val cache = ConcurrentHashMap<String, String?>()

    fun labelOf(packageName: String): String? {
        if (cache.containsKey(packageName)) return cache[packageName]
        val label = runCatching {
            val pm = context.packageManager
            val info = if (android.os.Build.VERSION.SDK_INT >= 33) {
                pm.getApplicationInfo(
                    packageName,
                    PackageManager.ApplicationInfoFlags.of(0L),
                )
            } else {
                @Suppress("DEPRECATION")
                pm.getApplicationInfo(packageName, 0)
            }
            pm.getApplicationLabel(info).toString()
        }.getOrNull()
        cache[packageName] = label
        return label
    }
}
