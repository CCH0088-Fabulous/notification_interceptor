package dev.poc.notifgen

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.CheckBox
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 手动/自动驱动生成器。界面刻意保持朴素：这个 App 只负责"生产第三方通知"，
 * 真正要看的界面是拦截器。
 */
class GeneratorActivity : Activity() {

    private val generator by lazy { Generator(this) }
    private val handler = Handler(Looper.getMainLooper())
    private val timeFormat = SimpleDateFormat("HH:mm:ss", Locale.getDefault())
    private val logLines = ArrayDeque<String>()

    private lateinit var permissionView: TextView
    private lateinit var logView: TextView
    private lateinit var autoButton: Button
    private lateinit var loudCheckBox: CheckBox
    private var autoRunning = false

    private val autoTick = object : Runnable {
        override fun run() {
            emit(1)
            if (autoRunning) handler.postDelayed(this, AUTO_INTERVAL_MS)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Generator.ensureChannels(this)
        setContentView(buildUi())
        refreshPermission()
    }

    override fun onDestroy() {
        autoRunning = false
        handler.removeCallbacks(autoTick)
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        refreshPermission()
    }

    private fun buildUi(): ScrollView {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(24), dp(20), dp(24))
        }

        root.addView(
            TextView(this).apply {
                text = getString(R.string.header_title)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
                setTypeface(typeface, Typeface.BOLD)
            },
        )
        root.addView(
            TextView(this).apply {
                text = getString(R.string.header_subtitle)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                setPadding(0, dp(6), 0, dp(14))
            },
        )
        root.addView(
            TextView(this).apply {
                text = "${getString(R.string.label_package)}：$packageName"
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                typeface = Typeface.MONOSPACE
            },
        )

        permissionView = TextView(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            setPadding(0, dp(4), 0, dp(12))
        }
        root.addView(permissionView)

        root.addView(
            button(getString(R.string.action_post_one)) { emit(1) },
        )
        root.addView(
            button(getString(R.string.action_post_ten)) { emit(10) },
        )
        autoButton = button(getString(R.string.action_auto_start)) {
            toggleAuto()
        }
        root.addView(autoButton)

        loudCheckBox = CheckBox(this).apply {
            text = getString(R.string.action_loud_mode)
            setPadding(0, dp(4), 0, dp(4))
        }
        root.addView(loudCheckBox)
        root.addView(
            button(getString(R.string.action_clear)) {
                generator.clearAll()
                appendLog("—— 已清空本应用通知 ——")
            },
        )

        if (!isNotificationPermissionGranted()) {
            root.addView(
                button(getString(R.string.action_grant)) { requestNotificationPermission() },
            )
        }
        root.addView(
            button(getString(R.string.action_listener_settings)) {
                runCatching {
                    startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                }
            },
        )

        root.addView(
            TextView(this).apply {
                text = getString(R.string.hint_whitelist)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                setPadding(0, dp(12), 0, dp(16))
            },
        )

        root.addView(
            TextView(this).apply {
                text = getString(R.string.section_log)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                setTypeface(typeface, Typeface.BOLD)
                setPadding(0, 0, 0, dp(6))
            },
        )

        logView = TextView(this).apply {
            text = getString(R.string.log_empty)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            typeface = Typeface.MONOSPACE
            setTextColor(Color.DKGRAY)
            setLineSpacing(dp(2).toFloat(), 1f)
            gravity = Gravity.START
        }
        root.addView(logView, LinearLayout.LayoutParams(-1, -2))

        return ScrollView(this).apply {
            addView(root, ViewGroup.LayoutParams(-1, -2))
            setBackgroundColor(Color.WHITE)
        }
    }

    private fun button(label: String, onClick: () -> Unit): Button =
        Button(this).apply {
            text = label
            setOnClickListener { onClick() }
            setPadding(dp(12), dp(4), dp(12), dp(4))
            layoutParams = LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(8) }
        }

    private fun emit(count: Int) {
        if (!isNotificationPermissionGranted()) {
            appendLog("⚠ 未授予通知权限，系统会静默丢弃")
            requestNotificationPermission()
        }
        val loud = loudCheckBox.isChecked
        val drafts = generator.post(count = count, loud = loud)
        drafts.forEach { draft ->
            val mark = when {
                draft.category.keep -> "应保留"
                loud -> "应拦截·会响"
                else -> "应拦截"
            }
            appendLog("${timeFormat.format(Date())} [${draft.category.label}·$mark] ${draft.text}")
        }
    }

    private fun toggleAuto() {
        autoRunning = !autoRunning
        autoButton.text = if (autoRunning) {
            getString(R.string.action_auto_stop)
        } else {
            getString(R.string.action_auto_start)
        }
        handler.removeCallbacks(autoTick)
        if (autoRunning) {
            handler.post(autoTick)
        } else {
            appendLog(getString(R.string.auto_stopped))
        }
    }

    private fun appendLog(line: String) {
        logLines.addLast(line)
        while (logLines.size > MAX_LOG_LINES) logLines.removeFirst()
        logView.text = logLines.joinToString("\n")
    }

    private fun refreshPermission() {
        permissionView.text = "${getString(R.string.label_permission)}：" +
            if (isNotificationPermissionGranted()) {
                getString(R.string.permission_granted)
            } else {
                getString(R.string.permission_missing)
            }
    }

    private fun isNotificationPermissionGranted(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_POST)
    }

    private fun dp(value: Int): Int =
        TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value.toFloat(),
            resources.displayMetrics,
        ).toInt()

    companion object {
        private const val REQUEST_POST = 100
        private const val MAX_LOG_LINES = 60
        private const val AUTO_INTERVAL_MS = 2_500L
    }
}
