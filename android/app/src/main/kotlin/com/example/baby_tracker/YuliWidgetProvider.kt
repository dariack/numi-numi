package com.example.baby_tracker

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.widget.RemoteViews
import android.app.PendingIntent
import android.content.Intent
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

            // Read pre-formatted strings from Flutter
            val feedLine1 = prefs.getString("feed_line1", "Feed: --") ?: "Feed: --"
            val feedLine2 = prefs.getString("feed_line2", "") ?: ""
            val sleepLine1 = prefs.getString("sleep_line1", "Sleep: --") ?: "Sleep: --"
            val sleepLine2 = prefs.getString("sleep_line2", "") ?: ""

            views.setTextViewText(R.id.feed_line1, feedLine1)
            views.setTextViewText(R.id.feed_line2, feedLine2)
            views.setTextViewText(R.id.sleep_line1, sleepLine1)
            views.setTextViewText(R.id.sleep_line2, sleepLine2)

            // Updated at
            val sdf = SimpleDateFormat("HH:mm", Locale.getDefault())
            views.setTextViewText(R.id.widget_updated, "Updated ${sdf.format(Date())}")

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}
