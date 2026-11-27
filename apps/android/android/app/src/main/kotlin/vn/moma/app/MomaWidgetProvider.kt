package vn.moma.app

import android.content.Context
import android.util.SizeF
import android.view.View
import android.widget.RemoteViews

/**
 * "Thao tác nhanh" (class name kept so widgets placed with older versions keep working). Ghi chi / Ghi thu open a
 * translucent quick-entry sheet, Nhận tiền opens the enlarged QR; only the AI actions open the full app.
 */
class MomaWidgetProvider : MomaWidgetBase() {
    override val buckets = listOf(
        SizeF(110f, 40f) to R.layout.wg_quick_row3,
        SizeF(110f, 110f) to R.layout.wg_quick_grid4,
        SizeF(250f, 40f) to R.layout.moma_widget,
        SizeF(250f, 110f) to R.layout.wg_quick_grid,
    )

    override fun bind(ctx: Context, views: RemoteViews, layout: Int) {
        views.setOnClickPendingIntent(R.id.widget_root, MomaWidgets.openApp(ctx, "home"))
        views.setOnClickPendingIntent(R.id.q_out, MomaWidgets.quickEntry(ctx, "expense"))
        views.setOnClickPendingIntent(R.id.q_in, MomaWidgets.quickEntry(ctx, "income"))
        views.setOnClickPendingIntent(R.id.q_qr, MomaWidgets.qrOverlay(ctx))
        if (layout != R.layout.wg_quick_row3) {
            views.setOnClickPendingIntent(R.id.q_ai, MomaWidgets.openApp(ctx, "ai"))
        }
        if (layout == R.layout.moma_widget || layout == R.layout.wg_quick_grid) {
            views.setOnClickPendingIntent(R.id.q_scan, MomaWidgets.openApp(ctx, "ai"))
        }
    }
}

/** "Chi tiêu hôm nay": today, month vs budget, budget left (rotating), last transaction. */
class SpendWidgetProvider : MomaWidgetBase() {
    override val buckets = listOf(
        SizeF(110f, 40f) to R.layout.wg_spend_strip,
        SizeF(110f, 110f) to R.layout.wg_spend_small,
        SizeF(250f, 110f) to R.layout.wg_spend_wide,
    )

    override fun bind(ctx: Context, views: RemoteViews, layout: Int) {
        val strip = layout == R.layout.wg_spend_strip
        val wide = layout == R.layout.wg_spend_wide
        views.setOnClickPendingIntent(R.id.widget_root, MomaWidgets.openApp(ctx, "home"))
        views.setOnClickPendingIntent(R.id.s_add, MomaWidgets.quickEntry(ctx, "expense"))
        if (!strip) views.setOnClickPendingIntent(R.id.s_refresh, MomaWidgets.refresh(ctx))

        val hide = WidgetStore.privacy(ctx)
        fun money(v: Long) = if (hide) MomaWidgets.HIDDEN else MomaWidgets.vnd(v)
        val has = WidgetStore.flag(ctx, "has_data")
        val sameDay = has && WidgetStore.str(ctx, "day") == MomaWidgets.today()
        val sameMonth = has && WidgetStore.str(ctx, "day").take(7) == MomaWidgets.today().take(7)
        val todaySpend = WidgetStore.num(ctx, "today_spend")
        val todayCount = WidgetStore.num(ctx, "today_count")
        val monthSpend = WidgetStore.num(ctx, "month_spend")
        val budget = WidgetStore.num(ctx, "budget")
        val monthNo = WidgetStore.str(ctx, "day").drop(5).take(2).toIntOrNull()
            ?: (java.util.Calendar.getInstance().get(java.util.Calendar.MONTH) + 1)
        val open = ctx.getString(R.string.wg_open_to_update)

        views.setTextViewText(R.id.s_today, if (sameDay) money(todaySpend) else "—")
        views.setTextViewText(R.id.s_month_label, "Tháng $monthNo")
        views.setTextViewText(R.id.s_month, if (sameMonth) money(monthSpend) else "—")
        val over = sameMonth && budget > 0 && monthSpend > budget
        views.setTextViewText(
            R.id.s_left_label,
            if (over) "Đã vượt ngân sách" else ctx.getString(R.string.wg_budget_left),
        )
        views.setTextViewText(
            R.id.s_left,
            when {
                !sameMonth -> "—"
                budget <= 0 -> "Chưa đặt"
                else -> money(kotlin.math.abs(budget - monthSpend))
            },
        )
        if (strip) return

        val pct = if (budget > 0) (monthSpend * 100 / budget).toInt() else 0
        views.setTextViewText(
            R.id.s_today_sub,
            when {
                !sameDay -> open
                todayCount > 0 -> "$todayCount khoản chi"
                else -> "Chưa có khoản chi"
            },
        )
        views.setTextViewText(
            R.id.s_month_sub,
            when {
                !sameMonth -> open
                budget <= 0 -> "Chưa đặt ngân sách"
                hide -> "$pct% ngân sách"
                else -> "$pct% ngân sách ${MomaWidgets.vnd(budget)}"
            },
        )
        views.setTextViewText(
            R.id.s_left_sub,
            when {
                !sameMonth -> open
                budget <= 0 -> "Đặt trong Kế hoạch"
                else -> "Còn ${MomaWidgets.daysLeftInMonth()} ngày trong tháng"
            },
        )
        val showBar = sameMonth && budget > 0
        views.setViewVisibility(R.id.s_progress, if (showBar && !over) View.VISIBLE else View.GONE)
        views.setViewVisibility(R.id.s_progress_over, if (showBar && over) View.VISIBLE else View.GONE)
        views.setProgressBar(R.id.s_progress, 100, pct.coerceIn(0, 100), false)

        val updatedAt = WidgetStore.num(ctx, "updated_at")
        val updated = when {
            WidgetStore.flag(ctx, "refreshing") -> ctx.getString(R.string.wg_updating)
            !has || updatedAt <= 0 -> open
            sameDay -> "Cập nhật " + java.text.SimpleDateFormat("HH:mm", java.util.Locale.US).format(java.util.Date(updatedAt))
            else -> "Cập nhật " + java.text.SimpleDateFormat("dd/MM", java.util.Locale.US).format(java.util.Date(updatedAt))
        }
        views.setTextViewText(R.id.s_updated, updated)

        if (wide) {
            val title = WidgetStore.str(ctx, "last_title")
            if (!has || title.isEmpty()) {
                views.setTextViewText(R.id.s_last, if (has) "Chưa có giao dịch" else open)
                views.setTextViewText(R.id.s_last_amount, "")
            } else {
                val kind = WidgetStore.str(ctx, "last_kind")
                val amount = WidgetStore.num(ctx, "last_amount")
                views.setTextViewText(R.id.s_last, "$title · ${WidgetStore.str(ctx, "last_time")}")
                val sign = when (kind) {
                    "in" -> "+"
                    "out" -> "−"
                    else -> ""
                }
                views.setTextViewText(R.id.s_last_amount, if (hide) MomaWidgets.HIDDEN else sign + MomaWidgets.vnd(amount))
                views.setTextColor(
                    R.id.s_last_amount,
                    ctx.getColor(if (kind == "in") R.color.wg_accent else R.color.wg_text),
                )
            }
        }
    }
}

/** "QR nhận tiền": the owner's VietQR rendered by the app; tap shows it enlarged without opening the app. */
class QrWidgetProvider : MomaWidgetBase() {
    override val buckets = listOf(
        SizeF(110f, 40f) to R.layout.wg_qr_strip,
        SizeF(110f, 110f) to R.layout.wg_qr_square,
        SizeF(250f, 110f) to R.layout.wg_qr_wide,
        SizeF(180f, 180f) to R.layout.wg_qr_big,
    )

    override fun bind(ctx: Context, views: RemoteViews, layout: Int) {
        // Layout ids differ per state, so the "empty" variants reuse the strip / empty layouts through ids below.
        bindState(ctx, views, layout)
    }

    private fun bindState(ctx: Context, views: RemoteViews, layout: Int) {
        val state = WidgetStore.str(ctx, "qr_state")
        val bmp = if (state == "ok") WidgetStore.qrBitmap(ctx) else null
        val bank = WidgetStore.str(ctx, "qr_bank")
        val masked = WidgetStore.str(ctx, "qr_masked")
        val holder = WidgetStore.str(ctx, "qr_holder")
        if (layout == R.layout.wg_qr_strip) {
            views.setTextViewText(
                R.id.r_caption,
                when {
                    bmp != null -> "$bank · $masked"
                    state == "unlinked" -> ctx.getString(R.string.wg_qr_unlinked)
                    else -> ctx.getString(R.string.wg_open_to_update)
                },
            )
            views.setOnClickPendingIntent(
                R.id.widget_root,
                if (state == "unlinked") MomaWidgets.openApp(ctx, "banks") else MomaWidgets.qrOverlay(ctx),
            )
            return
        }
        if (bmp == null) return // handled by QrWidgetProvider.views() swapping in the empty layout
        views.setImageViewBitmap(R.id.r_qr, bmp)
        views.setOnClickPendingIntent(R.id.widget_root, MomaWidgets.qrOverlay(ctx))
        when (layout) {
            R.layout.wg_qr_square -> {
                views.setTextViewText(R.id.r_caption, "$bank · $masked")
                views.setTextViewText(R.id.r_bank, bank)
                views.setTextViewText(R.id.r_masked, masked)
                views.setTextViewText(R.id.r_holder, holder)
            }
            R.layout.wg_qr_big -> {
                views.setTextViewText(R.id.r_bank, bank)
                views.setTextViewText(R.id.r_masked, if (holder.isEmpty()) masked else "$masked · $holder")
            }
            R.layout.wg_qr_wide -> {
                views.setTextViewText(R.id.r_bank, bank)
                views.setTextViewText(R.id.r_masked, masked)
                views.setTextViewText(R.id.r_holder, holder)
                views.setOnClickPendingIntent(R.id.r_amount_btn, MomaWidgets.openApp(ctx, "receive"))
                views.setOnClickPendingIntent(R.id.r_copy, MomaWidgets.copyNumber(ctx))
            }
        }
    }

    /** Without a QR the larger buckets show the "not linked / open MoMa" card instead. */
    override val emptyLayout: Int get() = R.layout.wg_qr_empty

    override fun bindEmpty(ctx: Context, views: RemoteViews) {
        val unlinked = WidgetStore.str(ctx, "qr_state") == "unlinked"
        views.setTextViewText(
            R.id.r_empty_title,
            ctx.getString(if (unlinked) R.string.wg_qr_unlinked else R.string.wg_open_to_update),
        )
        views.setTextViewText(
            R.id.r_empty_btn,
            ctx.getString(if (unlinked) R.string.wg_qr_link_btn else R.string.wg_qr_open_btn),
        )
        val target = MomaWidgets.openApp(ctx, if (unlinked) "banks" else "receive")
        views.setOnClickPendingIntent(R.id.r_empty_btn, target)
        views.setOnClickPendingIntent(R.id.widget_root, target)
    }

    override fun useEmpty(ctx: Context, layout: Int): Boolean =
        layout != R.layout.wg_qr_strip &&
            (WidgetStore.str(ctx, "qr_state") != "ok" || WidgetStore.qrBitmap(ctx) == null)
}

/** "Trợ lý tài chính": search-bar style entry to the AI assistant (needs the chat, so it opens the app). */
class AssistantWidgetProvider : MomaWidgetBase() {
    override val buckets = listOf(SizeF(110f, 40f) to R.layout.wg_assistant)

    override fun bind(ctx: Context, views: RemoteViews, layout: Int) {
        val ai = MomaWidgets.openApp(ctx, "ai")
        views.setOnClickPendingIntent(R.id.widget_root, ai)
        views.setOnClickPendingIntent(R.id.a_pill, ai)
        // Mic: opens the assistant already listening (Vietnamese speech input).
        views.setOnClickPendingIntent(R.id.a_photo, MomaWidgets.openApp(ctx, "ai?voice=1"))
    }
}
