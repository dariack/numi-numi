package com.example.baby_tracker

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.widget.RemoteViews
import android.app.PendingIntent
import android.content.Intent
import android.view.View
import java.text.SimpleDateFormat
import java.util.*

class YuliWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        for (appWidgetId in appWidgetIds) {
            val prefs = context.getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE)
            val views = RemoteViews(context.packageName, R.layout.widget_layout)

            // Tap anywhere to open app
            val intent = Intent(context, MainActivity::class.java)
            val pendingIntent = PendingIntent.getActivity(
                context, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_root, pendingIntent)

            // Slot data: label, value (big), optional sub-line
            // Format written by WidgetService: "label|value|sub" (sub optional)
            fun renderSlot(
                labelId: Int, valueId: Int, subId: Int, containerId: Int,
                key: String, accentColor: Int
            ) {
                val raw = prefs.getString(key, "") ?: ""
                if (raw.isEmpty()) {
                    views.setViewVisibility(containerId, View.GONE)
                    return
                }
                views.setViewVisibility(containerId, View.VISIBLE)
                val parts = raw.split("|")
                val label = parts.getOrElse(0) { "" }
                val value = parts.getOrElse(1) { "--" }
                val sub   = parts.getOrElse(2) { "" }

                views.setTextViewText(labelId, label)
                views.setTextViewText(valueId, value)
                views.setTextColor(valueId, accentColor)

                if (sub.isNotEmpty()) {
                    views.setTextViewText(subId, sub)
                    views.setViewVisibility(subId, View.VISIBLE)
                } else {
                    views.setViewVisibility(subId, View.GONE)
                }
            }

            // Colors matching app palette
            val orange = 0xFFf59e0b.toInt()
            val teal   = 0xFF2dd4bf.toInt()
            val purple = 0xFFa78bfa.toInt()
            val pink   = 0xFFf472b6.toInt()
            val white  = 0xFFE4E4E7.toInt()

            fun accentForType(type: String): Int = when (type) {
                "feed"   -> orange
                "sleep"  -> purple
                "diaper" -> teal
                "pump"   -> pink
                else     -> white
            }

            val slot1Raw = prefs.getString("widget_slot1", "") ?: ""
            val slot2Raw = prefs.getString("widget_slot2", "") ?: ""
            val slot1Type = prefs.getString("widget_slot1_type", "feed") ?: "feed"
            val slot2Type = prefs.getString("widget_slot2_type", "diaper") ?: "diaper"

            renderSlot(
                R.id.slot1_label, R.id.slot1_value, R.id.slot1_sub, R.id.slot1_container,
                "widget_slot1", accentForType(slot1Type)
            )
            renderSlot(
                R.id.slot2_label, R.id.slot2_value, R.id.slot2_sub, R.id.slot2_container,
                "widget_slot2", accentForType(slot2Type)
            )

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}
