package io.github.weqdevs.remote;

import android.content.Context;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.ImageButton;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

final class RemoteInstantView extends LinearLayout {
    final RemoteInstantStore.Snapshot snapshot;
    private RemoteInstantStore.Chat selected;
    private final TextView title, status;
    private final ImageButton back, retry;
    private final ScrollView scroll;
    private final LinearLayout rows;
    private final int ink, muted, line, accent;
    private boolean handingOff;

    RemoteInstantView(Context context, RemoteInstantStore.Snapshot snapshot, Runnable reconnect, Runnable manage) {
        super(context);
        this.snapshot = snapshot;
        boolean dark = (getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;
        ink = dark ? Color.rgb(236, 240, 240) : Color.rgb(24, 30, 31);
        muted = dark ? Color.rgb(170, 179, 180) : Color.rgb(88, 102, 104);
        line = dark ? Color.rgb(59, 67, 68) : Color.rgb(212, 220, 220);
        accent = dark ? Color.rgb(91, 212, 190) : Color.rgb(5, 122, 109);
        setBackgroundColor(dark ? Color.rgb(18, 20, 22) : Color.WHITE);
        setOrientation(VERTICAL);
        setOnApplyWindowInsetsListener((view, insets) -> {
            android.graphics.Rect bars = WindowInsetsHelper.contentInsets(insets);
            setPadding(bars.left, bars.top, bars.right, bars.bottom);
            return insets;
        });
        LinearLayout bar = new LinearLayout(context);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setPadding(dp(8), 0, dp(8), 0);
        addView(bar, new LayoutParams(-1, dp(48)));
        back = icon(getResources().getIdentifier("ic_arrow_right", "drawable", context.getPackageName()), "返回会话", this::back);
        back.setRotation(180);
        bar.addView(back, new LayoutParams(dp(44), -1));
        title = text("最近聊天", 17, ink, 1);
        title.setTypeface(null, Typeface.BOLD);
        bar.addView(title, new LayoutParams(0, -2, 1));
        retry = icon(android.R.drawable.ic_popup_sync, "重新连接", reconnect);
        bar.addView(retry, new LayoutParams(dp(44), -1));
        bar.addView(icon(getResources().getIdentifier("ic_more", "drawable", context.getPackageName()), "连接与配对", manage), new LayoutParams(dp(44), -1));
        status = text("正在同步", 13, muted, 1);
        status.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        status.setPadding(dp(16), 0, dp(16), dp(8));
        addView(status);
        separator(this);
        scroll = new ScrollView(context);
        rows = new LinearLayout(context);
        rows.setOrientation(VERTICAL);
        scroll.addView(rows, new FrameLayout.LayoutParams(-1, -2));
        addView(scroll, new LayoutParams(-1, 0, 1));
        list();
    }

    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    private TextView text(String value, int size, int color, int lines) {
        TextView view = new TextView(getContext());
        view.setText(value); view.setTextSize(size); view.setTextColor(color);
        if (lines > 0) { view.setMaxLines(lines); view.setEllipsize(android.text.TextUtils.TruncateAt.END); }
        return view;
    }
    private ImageButton icon(int resource, String label, Runnable action) {
        ImageButton button = new ImageButton(getContext());
        button.setImageResource(resource); button.setColorFilter(ink); button.setContentDescription(label);
        pressable(button); button.setOnClickListener(view -> action.run());
        return button;
    }
    private void pressable(View view) {
        TypedValue value = new TypedValue();
        if (getContext().getTheme().resolveAttribute(android.R.attr.selectableItemBackground, value, true)) view.setBackgroundResource(value.resourceId);
    }
    private void separator(LinearLayout parent) {
        View divider = new View(getContext());
        divider.setBackgroundColor(line); parent.addView(divider, new LayoutParams(-1, 1));
    }
    void updateStatus(boolean syncing, boolean handoff) {
        String label = syncing ? "正在同步" : "本机缓存 · 未连接";
        if (!android.text.TextUtils.equals(status.getText(), label)) status.setText(label);
        retry.setVisibility(syncing ? GONE : VISIBLE);
        handingOff = handoff;
    }
    @Override public boolean dispatchTouchEvent(android.view.MotionEvent event) {
        return handingOff || super.dispatchTouchEvent(event);
    }
    boolean back() {
        if (selected == null) return false;
        list(); return true;
    }
    String selection() { return selected == null ? null : selected.id; }
    String anchor() {
        if (selected == null || !scroll.canScrollVertically(1)) return null;
        for (int i = 0; i < rows.getChildCount(); i++) {
            View child = rows.getChildAt(i);
            if (child.getBottom() > scroll.getScrollY()) return (String)child.getTag();
        }
        return null;
    }
    private void list() {
        selected = null; title.setText("最近聊天"); title.setPadding(dp(8), 0, 0, 0); back.setVisibility(GONE);
        rows.removeAllViews(); rows.setPadding(0, 0, 0, 0); scroll.scrollTo(0, 0);
        for (RemoteInstantStore.Chat chat : snapshot.chats) {
            LinearLayout button = new LinearLayout(getContext());
            button.setOrientation(VERTICAL); button.setGravity(Gravity.CENTER_VERTICAL);
            button.setMinimumHeight(dp(56)); button.setPadding(dp(16), dp(7), dp(16), dp(7));
            TextView label = text(chat.title, 16, ink, 1); label.setTypeface(null, Typeface.BOLD);
            button.addView(label);
            button.addView(text(chat.rows.get(chat.rows.size() - 1).text, 14, muted, 1));
            pressable(button); button.setFocusable(true); button.setOnClickListener(view -> messages(chat));
            rows.addView(button, new LayoutParams(-1, -2)); separator(rows);
        }
    }
    private void messages(RemoteInstantStore.Chat chat) {
        selected = chat; back.setVisibility(VISIBLE); title.setPadding(0, 0, 0, 0); title.setText(chat.title);
        rows.removeAllViews(); rows.setPadding(dp(16), dp(12), dp(16), dp(12));
        for (RemoteInstantStore.Row row : chat.rows) {
            TextView bubble = text(row.text, 16, ink, 0);
            bubble.setTextIsSelectable(true); bubble.setTag(row.id);
            bubble.setPadding(dp(11), dp(8), dp(11), dp(8));
            GradientDrawable fill = new GradientDrawable();
            fill.setCornerRadius(dp(8));
            int tone = row.mine ? accent : muted;
            fill.setColor(Color.argb(32, Color.red(tone), Color.green(tone), Color.blue(tone)));
            bubble.setBackground(fill);
            LayoutParams params = new LayoutParams(-2, -2);
            params.gravity = row.mine ? Gravity.END : Gravity.START;
            params.setMargins(row.mine ? dp(36) : 0, 0, row.mine ? 0 : dp(36), dp(8));
            rows.addView(bubble, params);
        }
        scroll.post(() -> { if (selected == chat) scroll.scrollTo(0, rows.getHeight()); });
    }
}
