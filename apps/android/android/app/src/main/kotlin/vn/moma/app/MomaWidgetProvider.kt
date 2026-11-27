package vn.moma.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.RemoteViews

/**
 * Home-screen widget with three one-tap actions. It carries no financial data (nothing private is shown on a
 * locked or shared screen); each button opens the app straight on the right screen through a moma://app/... link.
 */
class MomaWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) {
            val views = RemoteViews(context.packageName, R.layout.moma_widget)
            views.setOnClickPendingIntent(R.id.widget_add, link(context, "quick-entry", 1))
            views.setOnClickPendingIntent(R.id.widget_receive, link(context, "receive", 2))
            views.setOnClickPendingIntent(R.id.widget_ai, link(context, "ai", 3))
            views.setOnClickPendingIntent(R.id.widget_root, link(context, "home", 4))
            manager.updateAppWidget(id, views)
        }
    }

    private fun link(context: Context, path: String, code: Int): PendingIntent {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("moma://app/$path")).apply {
            component = ComponentName(context, MainActivity::class.java)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        return PendingIntent.getActivity(
            context,
            code,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
