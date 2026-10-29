package dev.poc.notifgen

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.graphics.drawable.StateListDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsetsController
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.Switch
import android.widget.TextView
import java.text.SimpleDateFormat
import java.text.DecimalFormat
import java.text.DecimalFormatSymbols
import java.util.Date
import java.util.Locale

/** Category controls for manual demos. Broadcast verification keeps its own defaults. */
class GeneratorActivity : Activity() {
    private val generator by lazy { Generator(this) }
    private val preferences by lazy { getSharedPreferences("generator_controls", MODE_PRIVATE) }
    private val handler = Handler(Looper.getMainLooper())
    private val timeFormat = SimpleDateFormat("HH:mm:ss", Locale.getDefault())
    private val percentFormat = DecimalFormat("0.#", DecimalFormatSymbols(Locale.ROOT))
    private val uiTypeface by lazy { resources.getFont(R.font.source_han_serif_sc_regular) }
    private val logLines = ArrayDeque<String>()
    private val categoryControls = linkedMapOf<String, CheckBox>()

    private lateinit var permissionView: TextView
    private lateinit var permissionButton: Button
    private lateinit var stateView: TextView
    private lateinit var categoryHint: TextView
    private lateinit var logView: TextView
    private lateinit var sendButton: Button
    private lateinit var countInput: EditText
    private lateinit var countContainer: LinearLayout
    private lateinit var intervalContainer: LinearLayout
    private lateinit var configurationError: TextView
    private lateinit var realisticSwitch: Switch
    private lateinit var loudSwitch: Switch
    private lateinit var headsUpSwitch: Switch
    private lateinit var selection: CategorySelection
    private var updatingCategoryControls = false
    private var intervalIndex = 1
    private var sendModeIndex = 0
    private var restoringControls = true
    private var postedCount = 0
    private val intervalMs: Long get() = INTERVALS[intervalIndex]
    private val sendSession = SendSession()
    private var scheduledTick: Runnable? = null
    private var lastRunCompleted = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val savedIds = if (preferences.contains("category_ids")) {
            preferences.getStringSet("category_ids", emptySet())?.toSet() ?: emptySet()
        } else null
        selection = CategorySelection.restore(
            savedIds = savedIds,
            legacyCategoryId = preferences.getString("category", null),
            legacyGroup = preferences.getInt("group", 0),
        )
        intervalIndex = preferences.getInt("interval", 1).coerceIn(INTERVALS.indices)
        sendModeIndex = preferences.getInt("send_mode", 0).coerceIn(0..2)
        postedCount = savedInstanceState?.getInt("posted_count") ?: 0
        savedInstanceState?.getStringArrayList("log_lines")?.forEach(logLines::addLast)
        applySystemBarAppearance()
        Generator.ensureChannels(this)
        setContentView(buildUi())
        restoringControls = false
        refreshPermission()
        refreshCategorySelection()
        refreshConfiguration()
        refreshState()
        refreshLog()
        saveControls()
        window.decorView.post { applySystemBarAppearance() }
    }

    override fun onResume() {
        super.onResume()
        applySystemBarAppearance()
        if (::permissionView.isInitialized) refreshPermission()
        generator.refreshBannerSummary()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putInt("posted_count", postedCount)
        outState.putStringArrayList("log_lines", ArrayList(logLines))
        super.onSaveInstanceState(outState)
    }

    override fun onDestroy() {
        stopSending()
        generator.stopPendingUpdates()
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

    private fun buildUi(): View {
        val root = column().apply { setPadding(dp(18), dp(16), dp(18), dp(24)) }
        root.addView(text(getString(R.string.header_title), 24f, INK, true).apply {
            setPadding(0, 0, 0, dp(4))
        })
        root.addView(text(getString(R.string.header_subtitle), 12f, MUTED).apply {
            setPadding(0, 0, 0, dp(12))
        })
        root.addView(card().apply {
            setPadding(dp(14), dp(11), dp(14), dp(10))
            permissionView = text("", 14f, INK, true)
            addView(permissionView)
            addView(text(getString(R.string.permission_hint), 12f, MUTED).apply {
                setPadding(0, dp(3), 0, 0)
            })
            permissionButton = button(getString(R.string.action_grant)) {
                requestNotificationPermission()
            }
            addView(permissionButton)
        })
        root.addView(card().apply {
            addView(sectionTitle(getString(R.string.section_category), "01"))
            addView(text(getString(R.string.hint_category_multi), 12f, MUTED).apply {
                setPadding(0, 0, 0, dp(8))
            })
            addView(LinearLayout(this@GeneratorActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                addView(button(getString(R.string.action_select_all)) {
                    selection.selectAll()
                    onCategorySelectionChanged()
                }.apply {
                    layoutParams = LinearLayout.LayoutParams(0, dp(36), 1f).apply {
                        rightMargin = dp(8)
                        bottomMargin = dp(8)
                    }
                })
                addView(button(getString(R.string.action_clear_selection)) {
                    selection.clear()
                    onCategorySelectionChanged()
                }.apply {
                    layoutParams = LinearLayout.LayoutParams(0, dp(36), 1f).apply {
                        bottomMargin = dp(8)
                    }
                })
            })
            NoticeCorpus.CATEGORIES.chunked(2).forEach { categories ->
                addView(LinearLayout(this@GeneratorActivity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    categories.forEachIndexed { index, category ->
                        addView(categoryCheckBox(category).apply {
                            layoutParams = LinearLayout.LayoutParams(0, dp(48), 1f).apply {
                                if (index == 0) rightMargin = dp(8)
                                bottomMargin = dp(4)
                            }
                        })
                    }
                    if (categories.size == 1) addView(View(this@GeneratorActivity).apply {
                        layoutParams = LinearLayout.LayoutParams(0, dp(48), 1f)
                    })
                })
            }
            categoryHint = text("", 12f, MUTED).apply { setPadding(0, dp(4), 0, 0) }
            addView(categoryHint)
        })
        root.addView(card().apply {
            addView(sectionTitle(getString(R.string.section_send), "02"))
            stateView = text("", 12f, ACCENT, true).apply {
                setPadding(0, 0, 0, dp(10))
            }
            addView(stateView)
            addView(fieldLabel(getString(R.string.label_send_mode)))
            addView(spinner(SEND_MODE_LABELS.map { getString(it) }).apply {
                setSelection(sendModeIndex)
                onItemSelectedListener = selectionListener { index ->
                    if (sendModeIndex != index) {
                        sendModeIndex = index
                        onConfigurationChanged()
                    }
                }
            })
            countContainer = column().apply {
                addView(fieldLabel(getString(R.string.label_send_count)))
                countInput = EditText(this@GeneratorActivity).apply {
                    typeface = uiTypeface
                    textSize = 14f
                    includeFontPadding = false
                    setTextColor(INK)
                    setHintTextColor(MUTED)
                    inputType = InputType.TYPE_CLASS_NUMBER
                    setSingleLine(true)
                    setPadding(dp(12), dp(10), dp(12), dp(10))
                    background = shape(SURFACE, BORDER, 9)
                    layoutParams = LinearLayout.LayoutParams(-1, dp(50))
                    setText(preferences.getString("send_count", "10") ?: "10")
                    hint = getString(R.string.hint_send_count)
                    contentDescription = getString(R.string.label_send_count)
                    addTextChangedListener(object : TextWatcher {
                        override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
                        override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
                        override fun afterTextChanged(s: Editable?) { onConfigurationChanged() }
                    })
                }
                addView(countInput)
            }
            addView(countContainer)
            intervalContainer = column().apply {
                addView(fieldLabel(getString(R.string.label_interval)))
                addView(spinner(INTERVAL_LABELS.map { getString(it) }).apply {
                    setSelection(intervalIndex)
                    onItemSelectedListener = selectionListener { index ->
                        if (intervalIndex != index) {
                            intervalIndex = index
                            onConfigurationChanged()
                        }
                    }
                })
            }
            addView(intervalContainer)
            configurationError = text("", 12f, INK).apply {
                setPadding(0, dp(8), 0, 0)
            }
            addView(configurationError)
            addView(button(getString(R.string.action_clear)) {
                stopSending()
                generator.clearAll()
                appendLog(getString(R.string.log_notifications_cleared))
            })
            addView(text(getString(R.string.hint_observe), 12f, MUTED).apply {
                setPadding(0, dp(4), 0, 0)
            })
        })
        root.addView(card().apply {
            addView(sectionTitle(getString(R.string.section_behavior), "03"))
            realisticSwitch = modeSwitch(
                getString(R.string.action_realistic_mode),
                preferences.getBoolean("realistic", true),
            )
            addView(realisticSwitch)
            addView(text(getString(R.string.hint_realistic), 12f, MUTED).apply {
                setPadding(0, 0, 0, dp(12))
            })
            headsUpSwitch = modeSwitch(
                getString(R.string.action_heads_up_mode),
                preferences.getBoolean("heads_up", false),
            )
            addView(headsUpSwitch)
            addView(text(getString(R.string.hint_heads_up), 12f, MUTED).apply {
                setPadding(0, 0, 0, dp(12))
            })
            loudSwitch = modeSwitch(
                getString(R.string.action_loud_mode),
                preferences.getBoolean("loud", false),
            )
            addView(loudSwitch)
            addView(text(getString(R.string.hint_loud), 12f, MUTED))
        })
        root.addView(card().apply {
            addView(sectionTitle(getString(R.string.section_log), "04"))
            logView = text("", 12f, MUTED).apply {
                setTextIsSelectable(true)
                setLineSpacing(dp(4).toFloat(), 1f)
            }
            addView(logView)
            addView(button(getString(R.string.action_clear_log)) {
                logLines.clear()
                refreshLog()
            })
        })
        root.addView(button(getString(R.string.action_listener_settings)) {
            runCatching { startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)) }
                .onFailure { appendLog(getString(R.string.log_settings_unavailable)) }
        })
        root.addView(text(getString(R.string.hint_whitelist), 12f, MUTED).apply {
            setPadding(dp(2), dp(4), dp(2), 0)
        })
        val scroll = ScrollView(this).apply {
            isFillViewport = true
            clipToPadding = false
            setBackgroundColor(BACKGROUND)
            addView(root)
        }
        return column().apply {
            setBackgroundColor(BACKGROUND)
            addView(scroll, LinearLayout.LayoutParams(-1, 0, 1f))
            addView(View(this@GeneratorActivity).apply {
                setBackgroundColor(BORDER)
            }, LinearLayout.LayoutParams(-1, dp(1)))
            addView(column().apply {
                setPadding(dp(18), dp(10), dp(18), dp(10))
                sendButton = button(getString(R.string.action_send), primary = true) { toggleSending() }
                addView(sendButton, LinearLayout.LayoutParams(-1, dp(48)))
            })
            setOnApplyWindowInsetsListener { view, insets ->
                view.setPadding(
                    insets.systemWindowInsetLeft,
                    insets.systemWindowInsetTop,
                    insets.systemWindowInsetRight,
                    insets.systemWindowInsetBottom,
                )
                insets
            }
        }
    }

    private fun categoryCheckBox(category: Category): CheckBox = CheckBox(this).apply {
        typeface = uiTypeface
        includeFontPadding = false
        textSize = 13f
        setTextColor(INK)
        setPadding(dp(6), dp(3), dp(6), dp(3))
        gravity = Gravity.CENTER_VERTICAL
        buttonTintList = ColorStateList(
            arrayOf(intArrayOf(android.R.attr.state_checked), intArrayOf()),
            intArrayOf(INK, MUTED),
        )
        isChecked = selection.isSelected(category.id)
        categoryControls[category.id] = this
        setOnCheckedChangeListener { _, checked ->
            if (!updatingCategoryControls) {
                selection.setSelected(category.id, checked)
                onCategorySelectionChanged()
            }
        }
    }

    private fun onCategorySelectionChanged() {
        stopSending()
        refreshCategorySelection()
        refreshState()
        saveControls()
    }

    private fun refreshCategorySelection() {
        if (!::categoryHint.isInitialized) return
        updatingCategoryControls = true
        try {
            NoticeCorpus.CATEGORIES.forEach { category ->
                val control = categoryControls[category.id] ?: return@forEach
                val checked = selection.isSelected(category.id)
                val percentage = percentFormat.format(selection.probabilityPercent(category.id)) + "%"
                control.isChecked = checked
                control.text = category.label + "\n" + percentage
                control.background = shape(if (checked) SURFACE else BACKGROUND, BORDER, 7)
                control.contentDescription = getString(
                    R.string.category_accessibility,
                    category.label,
                    getString(if (checked) R.string.category_selected else R.string.category_unselected),
                    percentage,
                )
            }
        } finally {
            updatingCategoryControls = false
        }
        val count = selection.selectedIds.size
        categoryHint.text = if (count == 0) getString(R.string.hint_category_empty)
        else getString(R.string.hint_category_selected, count, NoticeCorpus.CATEGORIES.size)
        categoryHint.setTextColor(if (count == 0) INK else MUTED)
    }

    private fun emitOne(run: SendRun): Boolean {
        if (!sendSession.isActive(run)) return false
        if (!isNotificationPermissionGranted()) {
            appendLog(getString(R.string.log_permission_required))
            stopSending()
            requestNotificationPermission()
            return false
        }
        val configuration = run.configuration
        val drafts = runCatching {
            generator.post(
                count = 1,
                categoryIds = configuration.categoryIds,
                loud = configuration.loud,
                realistic = configuration.realistic,
                headsUp = configuration.headsUp,
            )
        }.getOrElse {
            appendLog(getString(R.string.log_send_failed, it.message ?: it.javaClass.simpleName))
            return false
        }
        if (drafts.isEmpty()) {
            appendLog(getString(R.string.log_send_empty))
            return false
        }
        drafts.forEach { draft ->
            postedCount++
            val expected = getString(
                if (draft.category.keep) R.string.expected_keep else R.string.expected_drop,
            )
            appendLog("[" + draft.category.label + " · " + expected + "] " + draft.title + "\n" + draft.text)
        }
        return true
    }

    private fun toggleSending() {
        if (sendSession.isRunning) {
            stopSending()
            appendLog(getString(R.string.log_send_stopped))
            return
        }
        refreshConfiguration()
        val configuration = currentConfiguration() ?: return
        if (!isNotificationPermissionGranted()) {
            appendLog(getString(R.string.log_permission_required))
            requestNotificationPermission()
            return
        }
        stopSending()
        lastRunCompleted = false
        val run = sendSession.start(configuration)
        refreshState()
        scheduleTick(run, 0)
    }

    private fun scheduleTick(run: SendRun, delayMs: Long) {
        if (!sendSession.isActive(run)) return
        val tick = Runnable {
            scheduledTick = null
            if (!sendSession.isActive(run)) return@Runnable
            if (!emitOne(run)) {
                stopSending()
                return@Runnable
            }
            val shouldContinue = sendSession.recordSent(run)
            if (shouldContinue && sendSession.isActive(run)) {
                scheduleTick(run, run.configuration.intervalMs)
            } else {
                lastRunCompleted = true
                appendLog(getString(R.string.log_send_complete, sendSession.sentCount))
            }
            refreshState()
        }
        scheduledTick = tick
        handler.postDelayed(tick, delayMs)
    }

    private fun currentConfiguration(): SendConfiguration? {
        if (selection.selectedIds.isEmpty()) return null
        val count = countInput.text.toString().trim().toIntOrNull()
        val mode = SEND_MODES[sendModeIndex]
        if (mode == SendMode.BATCH && (count == null || count !in 1..100)) return null
        return SendConfiguration(
            mode = mode,
            count = count ?: 10,
            intervalMs = intervalMs,
            categoryIds = selection.selectedIds,
            loud = loudSwitch.isChecked,
            realistic = realisticSwitch.isChecked,
            headsUp = headsUpSwitch.isChecked,
        )
    }

    private fun onConfigurationChanged() {
        if (restoringControls) return
        val wasRunning = sendSession.isRunning
        stopSending()
        if (wasRunning) {
            appendLog(getString(R.string.log_configuration_stopped))
        }
        refreshConfiguration()
        saveControls()
    }

    private fun stopSending() {
        scheduledTick?.let(handler::removeCallbacks)
        scheduledTick = null
        sendSession.stop()
        generator.stopPendingUpdates()
        lastRunCompleted = false
        refreshState()
    }

    private fun refreshConfiguration() {
        if (!::countContainer.isInitialized || !::intervalContainer.isInitialized ||
            !::configurationError.isInitialized || !::countInput.isInitialized
        ) return
        val mode = SEND_MODES[sendModeIndex]
        countContainer.visibility = if (mode == SendMode.BATCH) View.VISIBLE else View.GONE
        intervalContainer.visibility = if (mode == SendMode.SINGLE) View.GONE else View.VISIBLE
        val count = countInput.text.toString().trim().toIntOrNull()
        val invalidCount = mode == SendMode.BATCH && (count == null || count !in 1..100)
        configurationError.visibility = if (invalidCount) View.VISIBLE else View.GONE
        configurationError.text = if (invalidCount) getString(R.string.error_send_count) else ""
        refreshState()
    }

    private fun refreshState() {
        if (!::stateView.isInitialized || !::sendButton.isInitialized ||
            !::countInput.isInitialized || !::loudSwitch.isInitialized ||
            !::headsUpSwitch.isInitialized || !::realisticSwitch.isInitialized
        ) return
        val running = sendSession.isRunning
        sendButton.isEnabled = running || currentConfiguration() != null
        sendButton.text = getString(if (running) R.string.action_stop_send else R.string.action_send)
        val active = sendSession.activeRun
        val status = when {
            selection.selectedIds.isEmpty() -> getString(R.string.hint_category_empty)
            active?.configuration?.mode == SendMode.CONTINUOUS ->
                getString(R.string.state_continuous, sendSession.sentCount)
            active != null -> getString(
                R.string.state_sending,
                sendSession.sentCount,
                active.configuration.targetCount ?: 1,
            )
            lastRunCompleted -> getString(R.string.state_complete, sendSession.sentCount)
            else -> getString(R.string.state_ready)
        }
        stateView.text = getString(R.string.state_summary, status, postedCount)
    }

    private fun appendLog(line: String) {
        logLines.addFirst(timeFormat.format(Date()) + "  " + line)
        while (logLines.size > MAX_LOG_LINES) logLines.removeLast()
        refreshLog()
    }

    private fun refreshLog() {
        if (::logView.isInitialized) {
            logView.text = if (logLines.isEmpty()) getString(R.string.log_empty)
            else logLines.joinToString("\n\n")
        }
    }

    private fun saveControls() {
        preferences.edit()
            .putStringSet("category_ids", selection.selectedIds)
            .remove("group")
            .remove("category")
            .putInt("interval", intervalIndex)
            .putInt("send_mode", sendModeIndex)
            .apply {
                if (::countInput.isInitialized) putString("send_count", countInput.text.toString())
                if (::realisticSwitch.isInitialized) putBoolean("realistic", realisticSwitch.isChecked)
                if (::loudSwitch.isInitialized) putBoolean("loud", loudSwitch.isChecked)
                if (::headsUpSwitch.isInitialized) putBoolean("heads_up", headsUpSwitch.isChecked)
            }
            .apply()
    }

    private fun refreshPermission() {
        val granted = isNotificationPermissionGranted()
        permissionView.text = getString(
            if (granted) R.string.permission_granted else R.string.permission_missing,
        )
        permissionView.setTextColor(INK)
        permissionButton.visibility = if (granted) View.GONE else View.VISIBLE
        if (!granted) {
            if (sendSession.isRunning) stopSending()
            else generator.stopPendingUpdates()
        }
    }

    private fun isNotificationPermissionGranted(): Boolean {
        val manager = getSystemService(NotificationManager::class.java)
        val runtimeGranted = Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        return runtimeGranted && manager != null && manager.areNotificationsEnabled()
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
            (!preferences.getBoolean("permission_requested", false) ||
                shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS))
        ) {
            preferences.edit().putBoolean("permission_requested", true).apply()
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_POST)
        } else {
            runCatching {
                startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                    putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                })
            }.onFailure { appendLog(getString(R.string.log_settings_unavailable)) }
        }
    }

    private fun column(): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
    }

    private fun card(): LinearLayout = column().apply {
        setPadding(dp(14), dp(14), dp(14), dp(12))
        background = shape(Color.WHITE, BORDER, 9)
        layoutParams = LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(12) }
    }

    private fun sectionTitle(label: String, index: String): TextView =
        text(index + "  " + label, 16f, INK, true).apply { setPadding(0, 0, 0, dp(10)) }

    private fun fieldLabel(label: String): TextView = text(label, 12f, MUTED).apply {
        setPadding(0, dp(6), 0, dp(6))
    }

    private fun text(label: String, size: Float, color: Int, bold: Boolean = false): TextView =
        TextView(this).apply {
            text = label
            textSize = size
            setTextColor(color)
            setTypeface(uiTypeface, if (bold) Typeface.BOLD else Typeface.NORMAL)
            includeFontPadding = false
            layoutParams = LinearLayout.LayoutParams(-1, -2)
        }

    private fun adapter(labels: List<String>): ArrayAdapter<String> =
        object : ArrayAdapter<String>(this, android.R.layout.simple_spinner_item, labels) {
            init {
                setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
            }

            override fun getView(position: Int, convertView: View?, parent: ViewGroup): View =
                fontItem(super.getView(position, convertView, parent))

            override fun getDropDownView(position: Int, convertView: View?, parent: ViewGroup): View =
                fontItem(super.getDropDownView(position, convertView, parent))

            private fun fontItem(view: View): View = view.apply {
                (this as? TextView)?.apply {
                    typeface = uiTypeface
                    includeFontPadding = false
                    textSize = 14f
                    setTextColor(INK)
                    setPadding(dp(10), dp(8), dp(10), dp(8))
                    minHeight = dp(48)
                }
            }
        }

    private fun spinner(labels: List<String>): Spinner = Spinner(this).apply {
        adapter = this@GeneratorActivity.adapter(labels)
        minimumHeight = dp(48)
        setPadding(dp(8), 0, dp(6), 0)
        background = shape(SURFACE, BORDER, 9)
        layoutParams = LinearLayout.LayoutParams(-1, dp(50))
    }

    private fun modeSwitch(label: String, checked: Boolean): Switch = Switch(this).apply {
        text = label
        textSize = 14f
        typeface = uiTypeface
        includeFontPadding = false
        setTextColor(INK)
        minHeight = dp(48)
        isChecked = checked
        thumbTintList = ColorStateList(
            arrayOf(intArrayOf(android.R.attr.state_checked), intArrayOf()),
            intArrayOf(INK, Color.rgb(160, 160, 160)),
        )
        trackTintList = ColorStateList(
            arrayOf(intArrayOf(android.R.attr.state_checked), intArrayOf()),
            intArrayOf(Color.rgb(110, 110, 110), Color.rgb(220, 220, 220)),
        )
        setOnCheckedChangeListener { _, _ -> onConfigurationChanged() }
    }

    private fun button(label: String, primary: Boolean = false, onClick: () -> Unit): Button =
        Button(this).apply {
            text = label
            textSize = 14f
            typeface = uiTypeface
            includeFontPadding = false
            isAllCaps = false
            elevation = 0f
            stateListAnimator = null
            gravity = Gravity.CENTER
            minHeight = dp(48)
            setPadding(dp(12), dp(8), dp(12), dp(8))
            setTextColor(ColorStateList(
                arrayOf(intArrayOf(-android.R.attr.state_enabled), intArrayOf()),
                intArrayOf(Color.rgb(155, 155, 155), if (primary) Color.WHITE else INK),
            ))
            background = RippleDrawable(
                ColorStateList.valueOf(Color.argb(30, 100, 100, 100)),
                StateListDrawable().apply {
                    addState(intArrayOf(-android.R.attr.state_enabled), shape(SURFACE, BORDER, 9))
                    addState(intArrayOf(), shape(if (primary) INK else BACKGROUND, if (primary) INK else BORDER, 9))
                },
                null,
            )
            layoutParams = LinearLayout.LayoutParams(-1, -2).apply {
                topMargin = dp(6)
                bottomMargin = dp(4)
            }
            setOnClickListener { onClick() }
        }

    private fun selectionListener(onSelected: (Int) -> Unit) = object : AdapterView.OnItemSelectedListener {
        override fun onItemSelected(parent: AdapterView<*>?, view: View?, position: Int, id: Long) {
            onSelected(position)
        }
        override fun onNothingSelected(parent: AdapterView<*>?) = Unit
    }

    private fun shape(fill: Int, stroke: Int, radius: Int) = GradientDrawable().apply {
        setColor(fill)
        cornerRadius = dp(radius).toFloat()
        setStroke(dp(1), stroke)
    }

    private fun applySystemBarAppearance() {
        window.statusBarColor = Color.WHITE
        window.navigationBarColor = Color.WHITE
        window.decorView.systemUiVisibility =
            View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val darkIcons = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or
                WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS
            window.insetsController?.setSystemBarsAppearance(darkIcons, darkIcons)
        }
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density + 0.5f).toInt()

    companion object {
        private const val REQUEST_POST = 100
        private const val MAX_LOG_LINES = 60
        private val INTERVALS = longArrayOf(1_000L, 2_500L, 5_000L)
        private val INTERVAL_LABELS = intArrayOf(
            R.string.interval_one, R.string.interval_default, R.string.interval_five,
        )
        private val SEND_MODES = arrayOf(SendMode.SINGLE, SendMode.BATCH, SendMode.CONTINUOUS)
        private val SEND_MODE_LABELS = intArrayOf(
            R.string.send_mode_single, R.string.send_mode_batch, R.string.send_mode_continuous,
        )
        private val BACKGROUND = Color.WHITE
        private val SURFACE = Color.rgb(245, 245, 245)
        private val BORDER = Color.rgb(204, 204, 204)
        private val INK = Color.BLACK
        private val MUTED = Color.rgb(102, 102, 102)
        private val ACCENT = Color.BLACK
    }
}
