package com.example.baby_tracker

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.widget.RemoteViews
import android.net.Uri
import es.antonborri.home_widget.HomeWidgetLaunchIntent

class PoopWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        for (appWidgetId in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.widget_poop)

            val intent = HomeWidgetLaunchIntent.getActivity(
                context,
                MainActivity::class.java,
                Uri.parse("yuliTracker://logPoop")
            )
            views.setOnClickPendingIntent(R.id.poop_btn, intent)

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}
