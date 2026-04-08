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
            val pendingIntent = PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            views.setOnClickPendingIntent(R.id.widget_root, pendingIntent)

            // Each line: show if non-empty, hide if empty
            val feedLine = prefs.getString("feed_line1", "") ?: ""
            val sleepLine = prefs.getString("sleep_line1", "") ?: ""
            val diaperLine = prefs.getString("diaper_line1", "") ?: ""
            val pumpLine = prefs.getString("pump_line1", "") ?: ""

            views.setTextViewText(R.id.feed_line1, feedLine)
            views.setViewVisibility(R.id.feed_line1, if (feedLine.isNotEmpty()) View.VISIBLE else View.GONE)

            views.setTextViewText(R.id.sleep_line1, sleepLine)
            views.setViewVisibility(R.id.sleep_line1, if (sleepLine.isNotEmpty()) View.VISIBLE else View.GONE)

            views.setTextViewText(R.id.diaper_line1, diaperLine)
            views.setViewVisibility(R.id.diaper_line1, if (diaperLine.isNotEmpty()) View.VISIBLE else View.GONE)

            views.setTextViewText(R.id.pump_line1, pumpLine)
            views.setViewVisibility(R.id.pump_line1, if (pumpLine.isNotEmpty()) View.VISIBLE else View.GONE)

            // Updated at
            val sdf = SimpleDateFormat("HH:mm", Locale.getDefault())
            views.setTextViewText(R.id.widget_updated, "Updated ${sdf.format(Date())}")

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}
