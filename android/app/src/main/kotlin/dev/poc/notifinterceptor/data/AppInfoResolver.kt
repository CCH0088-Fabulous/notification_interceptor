package dev.poc.notifinterceptor.data

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import java.util.concurrent.ConcurrentHashMap

/** 包名 → 应用名，带缓存。避免请求 QUERY_ALL_PACKAGES 权限。 */
class AppInfoResolver(private val context: Context) {

    private val cache = ConcurrentHashMap<String, String>()

    fun labelOf(packageName: String): String? {
        cache[packageName]?.let { return it }
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
        // Android 11+ 的包可见性限制可能使应用名查询失败。
        // ConcurrentHashMap 不接受 null，名称缺失不能导致整条通知被丢弃。
        if (label != null) cache[packageName] = label
        return label
    }

    /** 可启动的已安装应用，加上历史或现有规则中的通知来源。 */
    fun availableApps(extraPackages: Collection<String>): Map<String, String> {
        val pm = context.packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        @Suppress("DEPRECATION")
        val launchable = pm.queryIntentActivities(intent, 0)
        val packages = launchable.map { it.activityInfo.packageName } + extraPackages
        return packages.asSequence()
            .filter { it.isNotBlank() && it != context.packageName }
            .distinct()
            .associateWith { labelOf(it)?.takeIf(String::isNotBlank) ?: it }
    }
}
