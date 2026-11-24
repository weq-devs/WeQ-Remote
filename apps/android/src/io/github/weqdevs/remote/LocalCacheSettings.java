package io.github.weqdevs.remote;

import android.app.AlertDialog;
import android.text.Editable;
import android.text.InputType;
import android.text.TextWatcher;
import android.view.View;
import android.webkit.WebView;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.Proxy;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Locale;
import org.json.JSONObject;

final class LocalCacheSettings {
    private static final long MIB = 1L << 20;
    private static final String PATH = "/_weq-remote-local/cache";
    private final MainActivity activity;
    private final WebView page;
    private final String origin, cookie;

    LocalCacheSettings(MainActivity activity, WebView page, String origin, String secret) {
        this.activity = activity;
        this.page = page;
        this.origin = origin;
        this.cookie = "weq_remote_local=" + secret;
    }

    void addRows(LinearLayout group) { new Rows(group).read(); }

    private boolean isCurrent() { return page == activity.webView && !activity.isDestroyed(); }

    private JSONObject request(String method, int limit) throws Exception {
        String query = "PUT".equals(method) ? "?limit=" + (limit * MIB) : "";
        HttpURLConnection connection = (HttpURLConnection) new URL(origin + PATH + query).openConnection(Proxy.NO_PROXY);
        connection.setRequestMethod(method);
        connection.setRequestProperty("Cookie", cookie);
        connection.setInstanceFollowRedirects(false);
        connection.setConnectTimeout(5000);
        connection.setReadTimeout(12000);
        connection.setUseCaches(false);
        try {
            if (connection.getResponseCode() != 200 || !"1".equals(connection.getHeaderField("X-WeQ-Data-Cache"))) {
                throw new IOException("Local cache unavailable");
            }
            try (InputStream input = connection.getInputStream(); ByteArrayOutputStream body = new ByteArrayOutputStream()) {
                byte[] buffer = new byte[256];
                for (int count; (count = input.read(buffer)) != -1;) {
                    if (body.size() + count > 4096) throw new IOException("Invalid local cache status");
                    body.write(buffer, 0, count);
                }
                return new JSONObject(new String(body.toByteArray(), StandardCharsets.UTF_8));
            }
        } finally {
            connection.disconnect();
        }
    }

    private void notifyPage(boolean cleared) {
        String url = page.getUrl();
        if (!WebAccess.sameOrigin(origin, url)) return;
        page.evaluateJavascript("(function(){if(typeof window.weqLocalCacheChanged!=='function')return false;"
            + "window.weqLocalCacheChanged(" + cleared + ");return true;})()", result -> {
                if (cleared && !"true".equals(result) && isCurrent() && url.equals(page.getUrl())) page.reload();
            });
    }

    private final class Rows {
        private final TextView usage = new TextView(activity);
        private final TextView notice = new TextView(activity);
        private final Button edit = button("缓存上限", this::editLimit);
        private final Button clear = button("清除业务缓存", this::confirmClear);
        private final Button retry = button("重试读取", this::read);
        private int limit;

        Rows(LinearLayout group) {
            notice.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
            group.addView(usage);
            group.addView(edit);
            group.addView(clear);
            group.addView(notice);
            group.addView(retry);
        }

        void read() { run("GET", 0, "无法读取本机缓存，请重试。", null); }

        private void run(String method, int value, String failure, String success) {
            if (!isCurrent()) return;
            edit.setEnabled(false);
            clear.setEnabled(false);
            retry.setVisibility(View.GONE);
            usage.setVisibility(limit > 0 ? View.VISIBLE : View.GONE);
            edit.setVisibility(usage.getVisibility());
            clear.setVisibility(usage.getVisibility());
            notice.setVisibility(View.VISIBLE);
            notice.setText(limit == 0 ? "正在读取本机缓存…" : "正在更新本机缓存…");
            activity.cacheWorker.execute(() -> {
                try {
                    JSONObject status = request(method, value);
                    long bytes = status.getLong("bytes");
                    int limitMiB = (int) (status.getLong("limit") / MIB);
                    activity.main.post(() -> {
                        if (!isCurrent()) return;
                        limit = limitMiB;
                        usage.setText(String.format(Locale.getDefault(), "已用空间：%.1f MiB", (double) bytes / MIB));
                        usage.setVisibility(View.VISIBLE);
                        edit.setText("缓存上限：" + limit + " MiB");
                        edit.setVisibility(View.VISIBLE);
                        clear.setVisibility(View.VISIBLE);
                        finish(success);
                        if (success != null) notifyPage("DELETE".equals(method));
                    });
                } catch (Exception error) {
                    activity.main.post(() -> { if (isCurrent()) finish(failure); });
                }
            });
        }

        private void finish(String message) {
            edit.setEnabled(limit > 0);
            clear.setEnabled(limit > 0);
            retry.setVisibility(limit == 0 ? View.VISIBLE : View.GONE);
            notice.setText(message);
            notice.setVisibility(message == null ? View.GONE : View.VISIBLE);
        }

        private void editLimit() {
            if (!isCurrent()) return;
            EditText input = new EditText(activity);
            input.setSingleLine(true);
            input.setInputType(InputType.TYPE_CLASS_NUMBER);
            input.setText(String.valueOf(limit));
            input.setSelectAllOnFocus(true);
            input.setContentDescription("缓存上限（MiB）");
            LinearLayout field = new LinearLayout(activity);
            int inset = Math.round(24 * activity.getResources().getDisplayMetrics().density);
            field.setPadding(inset, 0, inset, 0);
            field.addView(input, new LinearLayout.LayoutParams(-1, -2));
            AlertDialog dialog = new AlertDialog.Builder(activity).setTitle("缓存上限（MiB）")
                .setMessage("输入 16–4096 MiB。超出上限时优先清理最久未使用的数据。")
                .setView(field).setNegativeButton("取消", null).setPositiveButton("保存", (view, which) -> {
                    int value = parseLimit(input);
                    if (value != 0 && value != limit) run("PUT", value, "无法保存缓存上限，请重试。", "缓存上限已保存。");
                }).show();
            Button save = dialog.getButton(AlertDialog.BUTTON_POSITIVE);
            save.setEnabled(false);
            input.addTextChangedListener(new TextWatcher() {
                public void beforeTextChanged(CharSequence value, int start, int count, int after) { }
                public void onTextChanged(CharSequence value, int start, int before, int count) {
                    int parsed = parseLimit(input);
                    save.setEnabled(parsed != 0 && parsed != limit);
                }
                public void afterTextChanged(Editable value) { }
            });
        }

        private void confirmClear() {
            if (!isCurrent()) return;
            new AlertDialog.Builder(activity).setTitle("清除业务缓存？")
                .setMessage("将清除当前电脑的本机聊天、图片和其他业务缓存。网页代码和配对信息会保留。")
                .setNegativeButton("取消", null).setPositiveButton("清除", (view, which) ->
                    run("DELETE", 0, "无法清除业务缓存，请重试。", "已清除业务缓存。")).show();
        }

        private Button button(String title, Runnable action) {
            Button button = new Button(activity);
            button.setAllCaps(false);
            button.setText(title);
            button.setOnClickListener(view -> action.run());
            return button;
        }
    }

    private static int parseLimit(EditText input) {
        try {
            int value = Integer.parseInt(input.getText().toString());
            return value >= 16 && value <= 4096 ? value : 0;
        } catch (NumberFormatException ignored) { return 0; }
    }
}
