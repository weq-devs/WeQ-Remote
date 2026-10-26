package io.github.weqdevs.remote;

import android.app.Activity;
import android.content.Intent;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.View;
import android.view.WindowInsets;
import android.view.inputmethod.InputMethodManager;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.net.URI;
import java.text.DateFormat;
import java.util.Date;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import org.json.JSONObject;
import androidnet.Androidnet;
import androidnet.Client;

public final class MainActivity extends Activity {
    final Handler main = new Handler(Looper.getMainLooper());
    final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final ExecutorService closer = Executors.newSingleThreadExecutor();
    private Client node;
    private volatile int generation;
    private volatile Future<?> closing;
    private boolean enabled, online, busy, paired, visible;
    private String loginURL, endpoint, token, claimID;
    private String fingerprint;
    private String connectionRoutes;
    private boolean restoring;
    private boolean rememberedComputer;
    private long expiresAt;
    private String testControl;
    private String networkDirectory;
    private Invitation enrolling;
    private long enrollmentDeadline;
    private View setupView;
    android.webkit.WebView webView;
    TextView networkState, computerState, detail, error;
    EditText invitation;
    Button pairButton, verifyButton, disconnectButton;
    private LinearLayout pairSection;
    private TextView webNotice;
    private TextView pageSubtitle;
    private Button scanButton;
    private final Runnable networkPoll = new Runnable() { public void run() { refreshNetwork(); } };
    private final Runnable approvalPoll = new Runnable() { public void run() { pollApproval(); } };
    private final Runnable reconnectPoll = () -> {
        if (!visible || busy) return;
        if (webView != null) verify();
        else if (claimID == null) restoreComputer();
    };

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        go.Seq.setContext(getApplicationContext());
        if (BuildConfig.TESTING && getIntent().getBooleanExtra("isolated_ts_test", false)) {
            String control = getIntent().getStringExtra("test_control");
            try {
                URI uri = new URI(control);
                if ("http".equals(uri.getScheme()) && "127.0.0.1".equals(uri.getHost()) && uri.getPort() > 0 && uri.getUserInfo() == null && "".equals(uri.getPath()) && uri.getQuery() == null && uri.getFragment() == null) testControl = control;
            } catch (Exception ignored) { }
        }
        try { rememberedComputer = getIntent().getData() == null && ConnectionStore.load(this) != null; } catch (Exception ignored) { }
        buildUI();
        if (!BuildConfig.TESTING) getWindow().addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE);
        invitation.setSaveEnabled(false);
        if (testControl == null) {
            String selected = getPreferences(MODE_PRIVATE).getString("networkState", "");
            if (selected.matches("enrolled-[a-f0-9]{64}")) networkDirectory = new java.io.File(new java.io.File(getNoBackupFilesDir(), "tailnet"), selected).getAbsolutePath();
        }
        if (getIntent().getData() != null) invitation.setText(getIntent().getData().toString());
        if (testControl != null) { invitation.setText(getIntent().getStringExtra("test_invitation")); enabled = true; }
    }

    @Override protected void onResume() {
        super.onResume(); visible = true;
        if (webView != null) { webView.onResume(); verify(); return; }
        if (!BuildConfig.TESTING && invitation.length() > 0) { main.post(this::pair); return; }
        if (node == null && !busy && !restoreComputer() && enabled) startNetwork();
    }
    @Override protected void onStop() {
        visible = false;
        main.removeCallbacks(reconnectPoll);
        if (webView == null) stopNetwork(false);
        super.onStop();
    }
    @Override protected void onPause() {
        if (webView != null) webView.onPause();
        super.onPause();
    }
    @Override protected void onDestroy() {
        stopNetwork(true);
        main.removeCallbacksAndMessages(null);
        worker.shutdownNow(); closer.shutdown();
        super.onDestroy();
    }
    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if (intent.getData() != null) { invitation.setText(intent.getData().toString()); main.post(this::pair); }
    }

    private void buildUI() {
        boolean dark = (getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;
        ScrollView scroll = new ScrollView(this);
        setupView = scroll;
        LinearLayout content = new LinearLayout(this); content.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(28); content.setPadding(pad, pad, pad, pad);
        int accent = dark ? Color.rgb(91, 212, 190) : Color.rgb(5, 122, 109);
        scroll.setFillViewport(true);
        scroll.setBackgroundColor(dark ? Color.rgb(18, 20, 22) : Color.rgb(245, 247, 247));
        android.widget.FrameLayout frame = new android.widget.FrameLayout(this);
        android.widget.FrameLayout.LayoutParams width = new android.widget.FrameLayout.LayoutParams(Math.min(getResources().getDisplayMetrics().widthPixels, dp(496)), -2, android.view.Gravity.TOP | android.view.Gravity.CENTER_HORIZONTAL);
        frame.addView(content, width); scroll.addView(frame); setContentView(scroll);
        if (android.os.Build.VERSION.SDK_INT >= 30) scroll.setOnApplyWindowInsetsListener((view, insets) -> {
            android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.ime());
            content.setPadding(pad + bars.left, pad + bars.top, pad + bars.right, pad + bars.bottom); return insets;
        });
        android.widget.ImageView computer = new android.widget.ImageView(this); computer.setImageResource(getResources().getIdentifier("ic_computer", "drawable", getPackageName())); computer.setColorFilter(accent); computer.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        LinearLayout.LayoutParams mark = new LinearLayout.LayoutParams(dp(40), dp(40)); mark.topMargin = dp(24); mark.bottomMargin = dp(24); content.addView(computer, mark);
        TextView title = text("WeQ Remote", 30); title.setTypeface(null, android.graphics.Typeface.BOLD); content.addView(title);
        pageSubtitle = text("连接电脑", 20); pageSubtitle.setTextColor(dark ? Color.rgb(170, 179, 180) : Color.rgb(98, 110, 112)); pageSubtitle.setPadding(0, dp(8), 0, dp(32)); content.addView(pageSubtitle);
        networkState = text("App 内网络：未启动", 16);
        pairSection = new LinearLayout(this); pairSection.setOrientation(LinearLayout.VERTICAL); content.addView(pairSection);
        scanButton = button("扫码连接", () -> startActivityForResult(new Intent(this, ScannerActivity.class), 7)); scanButton.setContentDescription("扫码"); scanButton.setTextColor(dark ? Color.rgb(13, 35, 31) : Color.WHITE); scanButton.setTextSize(18); scanButton.setGravity(android.view.Gravity.CENTER); scanButton.setBackground(new android.graphics.drawable.RippleDrawable(android.content.res.ColorStateList.valueOf(0x30ffffff), background(accent, accent), null)); scanButton.setPadding(dp(20), dp(16), dp(20), dp(16));
        for (android.graphics.drawable.Drawable icon : scanButton.getCompoundDrawables()) { if (icon != null) icon.setTint(scanButton.getCurrentTextColor()); }
        pairSection.addView(scanButton, new LinearLayout.LayoutParams(-1, dp(88)));
        section(pairSection, "配对链接");
        LinearLayout input = new LinearLayout(this); input.setGravity(android.view.Gravity.CENTER_VERTICAL); input.setPadding(dp(14), dp(4), dp(6), dp(4)); input.setBackground(background(dark ? Color.rgb(30, 34, 35) : Color.WHITE, dark ? Color.rgb(59, 67, 68) : Color.rgb(212, 220, 220))); pairSection.addView(input);
        invitation = new EditText(this); invitation.setHint("粘贴配对链接"); invitation.setTextSize(16); invitation.setBackgroundColor(Color.TRANSPARENT); invitation.setSingleLine(true); invitation.setMinHeight(dp(52)); invitation.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_URI | android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS); invitation.setImeOptions(android.view.inputmethod.EditorInfo.IME_ACTION_GO); invitation.setOnEditorActionListener((view, action, event) -> { if (action == android.view.inputmethod.EditorInfo.IME_ACTION_GO) { pair(); return true; } return false; }); invitation.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO); input.addView(invitation, new LinearLayout.LayoutParams(0, -2, 1));
        pairButton = button("", this::pair); pairButton.setContentDescription("连接电脑"); pairButton.setCompoundDrawablesWithIntrinsicBounds(android.R.drawable.ic_media_play, 0, 0, 0); pairButton.setMinWidth(0); pairButton.setMinimumWidth(0); pairButton.setPadding(dp(12), 0, dp(12), 0); input.addView(pairButton, new LinearLayout.LayoutParams(dp(48), dp(48)));
        computerState = text(rememberedComputer ? "正在连接电脑" : "未配对", 18); computerState.setTypeface(null, android.graphics.Typeface.BOLD); computerState.setPadding(0, dp(32), 0, 0); content.addView(computerState);
        detail = text("", 14); detail.setPadding(0, dp(10), 0, dp(10)); content.addView(detail);
        verifyButton = button("验证连通", this::verify); verifyButton.setVisibility(View.GONE); content.addView(verifyButton);
        Button retry = button("重新连接", () -> restoreComputer()); retry.setCompoundDrawablesWithIntrinsicBounds(android.R.drawable.ic_popup_sync, 0, 0, 0); retry.setVisibility(rememberedComputer ? View.VISIBLE : View.GONE); content.addView(retry); retry.setTag("retry");
        disconnectButton = button("删除电脑", this::forgetComputer); disconnectButton.setVisibility(View.GONE); content.addView(disconnectButton);
        error = text("", 14); error.setTextColor(dark ? Color.rgb(255, 160, 150) : Color.rgb(170, 35, 30)); error.setPadding(0, dp(12), 0, 0); content.addView(error);
        invitation.addTextChangedListener(new android.text.TextWatcher() {
            public void beforeTextChanged(CharSequence s, int start, int count, int after) { }
            public void onTextChanged(CharSequence s, int start, int before, int count) { render(); }
            public void afterTextChanged(android.text.Editable value) { }
        });
        render();
    }
    private TextView text(String value, int size) { TextView view = new TextView(this); view.setText(value); view.setTextSize(size); view.setLineSpacing(dp(3), 1); return view; }
    private android.graphics.drawable.Drawable background(int fill, int border) {
        GradientDrawable shape = new GradientDrawable(); shape.setColor(fill); shape.setCornerRadius(dp(8)); shape.setStroke(dp(1), border); return shape;
    }
    private void section(LinearLayout parent, String name) { TextView heading = text(name, 14); heading.setTypeface(null, 1); heading.setPadding(0, dp(30), 0, dp(12)); parent.addView(heading); }
    private Button button(String label, Runnable action) {
        Button button = new Button(this); button.setText(label); button.setAllCaps(false); button.setMinHeight(dp(50)); button.setMaxLines(2);
        int resource = label.startsWith("扫码") ? getResources().getIdentifier("ic_scan", "drawable", getPackageName()) : label.equals("粘贴链接") ? android.R.drawable.ic_menu_edit : label.equals("验证连通") ? android.R.drawable.ic_popup_sync : 0;
        if (resource != 0) { android.graphics.drawable.Drawable icon = getDrawable(resource).mutate(); icon.setTint(button.getCurrentTextColor()); button.setCompoundDrawablesWithIntrinsicBounds(icon, null, null, null); button.setCompoundDrawablePadding(dp(8)); }
        button.setOnClickListener(v -> action.run()); return button;
    }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }

    private void render() {
        pageSubtitle.setText(rememberedComputer ? "我的电脑" : "连接电脑");
        scanButton.setEnabled(!busy);
        if (rememberedComputer && busy && !paired) computerState.setText("正在连接电脑");
        computerState.setVisibility(busy || paired || claimID != null || rememberedComputer ? View.VISIBLE : View.GONE);
        detail.setVisibility(detail.length() > 0 ? View.VISIBLE : View.GONE);
        detail.setTextSize(claimID != null && !paired ? 28 : 14);
        pairButton.setEnabled(!busy && claimID == null && invitation.length() > 0);
        pairButton.setVisibility(invitation.length() > 0 ? View.VISIBLE : View.GONE);
        verifyButton.setVisibility(paired && BuildConfig.TESTING ? View.VISIBLE : View.GONE); verifyButton.setEnabled(!busy);
        disconnectButton.setVisibility(paired || claimID != null || rememberedComputer ? View.VISIBLE : View.GONE);
        pairSection.setVisibility(paired || claimID != null || rememberedComputer ? View.GONE : View.VISIBLE);
        View retry = setupView.findViewWithTag("retry"); retry.setVisibility(rememberedComputer && !paired ? View.VISIBLE : View.GONE); retry.setEnabled(!busy);
    }

    private void forgetComputer() { ConnectionStore.delete(this); rememberedComputer = false; Androidnet.clearWebCache(); stopNetwork(true); }

    private void startNetwork() {
        startNetwork(null);
    }
    private void startNetwork(String authKey) {
        if (busy || node != null || !visible) return;
        busy = true; error.setText(""); networkState.setText("App 内网络：正在连接"); render();
        final int revision = generation;
        worker.execute(() -> {
            try {
                Future<?> pendingClose = closing;
                if (pendingClose != null) pendingClose.get();
                go.Seq.setContext(getApplicationContext());
                Androidnet.setInterfaces(interfaceSnapshot());
                if (revision != generation || !visible) return;
                String base = new java.io.File(getNoBackupFilesDir(), testControl == null ? "tailnet" : "tailnet-integration").getAbsolutePath();
                String directory = authKey != null ? Androidnet.authStateDir(base, authKey) : networkDirectory != null ? networkDirectory : base;
                Client client = testControl != null ? Androidnet.newTestClient(directory, testControl) : authKey != null ? Androidnet.newEnrolledClient(directory, authKey) : Androidnet.newClient(directory);
                main.post(() -> {
                    if (revision != generation || !visible) { closeClient(client); return; }
                    networkDirectory = directory; node = client; busy = false; refreshNetwork();
                });
            } catch (Exception e) { main.post(() -> { if (revision == generation) { enrolling = null; busy = false; enabled = false; error.setText("网络启动失败，请重新生成一次性 Key 后重试"); networkState.setText("App 内网络：未启动"); render(); } }); }
        });
    }
    private void refreshNetwork() {
        final Client client = node; final int revision = generation;
        if (client == null || !visible) return;
        worker.execute(() -> {
            try {
                JSONObject status = new JSONObject(client.status());
                String state = status.getString("state"); String auth = status.optString("loginURL");
                main.post(() -> {
                    if (revision != generation) return;
                    online = "Running".equals(state); loginURL = safeLogin(auth);
                    networkState.setText("App 内网络：" + (online ? "已连接" : "NeedsMachineAuth".equals(state) ? "等待网络管理员批准" : loginURL != null ? "等待网络登录" : "正在连接"));
                    if (restoring && online) { busy = false; verify(); return; }
                    if (restoring && loginURL != null) { stopNetwork(true); error.setText("网络授权需更新，请在电脑重新生成配对码"); return; }
                    if (enrolling != null) {
                        if (online) { Invitation link = enrolling; enrolling = null; getPreferences(MODE_PRIVATE).edit().putString("networkState", new java.io.File(networkDirectory).getName()).apply(); claim(link); return; }
                        if (SystemClock.elapsedRealtime() >= enrollmentDeadline || System.currentTimeMillis() >= enrolling.expiresAt || loginURL != null || "NeedsMachineAuth".equals(state)) {
                            stopNetwork(true); error.setText("入网未完成，请检查 Key 是否已使用、过期或需要管理员批准，再重新生成邀请"); return;
                        }
                        busy = true;
                    }
                    render();
                    if (!online && loginURL == null) main.postDelayed(networkPoll, 1500);
                });
            } catch (Exception e) { main.post(() -> { if (revision == generation) { stopNetwork(true); error.setText("网络状态读取失败，请重新连接"); render(); } }); }
        });
    }
    private String safeLogin(String value) {
        try { URI url = new URI(value); return "https".equals(url.getScheme()) && "login.tailscale.com".equals(url.getHost()) && url.getUserInfo() == null && (url.getPort() == -1 || url.getPort() == 443) ? value : null; }
        catch (Exception e) { return null; }
    }
    private String interfaceSnapshot() throws Exception {
        org.json.JSONArray result = new org.json.JSONArray();
        java.util.Enumeration<java.net.NetworkInterface> values = java.net.NetworkInterface.getNetworkInterfaces();
        while (values != null && values.hasMoreElements()) {
            java.net.NetworkInterface value = values.nextElement();
            int flags = (value.isUp() ? 1 : 0) | (value.isLoopback() ? 4 : 2) | (value.isPointToPoint() ? 8 : 0) | (value.supportsMulticast() ? 16 : 0);
            org.json.JSONArray addresses = new org.json.JSONArray();
            for (java.net.InterfaceAddress address : value.getInterfaceAddresses()) {
                addresses.put(address.getAddress().getHostAddress().split("%")[0] + "/" + address.getNetworkPrefixLength());
            }
            result.put(new JSONObject().put("name", value.getName()).put("index", value.getIndex()).put("mtu", value.getMTU()).put("flags", flags).put("addresses", addresses));
        }
        return result.toString();
    }
    private void stopNetwork(boolean disable) {
        generation++; if (disable) enabled = false;
        enrolling = null; invitation.setText("");
        main.removeCallbacks(networkPoll); main.removeCallbacks(approvalPoll); main.removeCallbacks(reconnectPoll);
        Client previous = node; node = null; online = false; loginURL = null; busy = false;
        clearComputer(); networkState.setText(enabled ? "App 内网络：已暂停" : "App 内网络：未启动"); render();
        if (previous != null) closeClient(previous);
    }
    private void closeClient(Client client) {
        try { closing = closer.submit(client::close); }
        catch (java.util.concurrent.RejectedExecutionException stopped) { Thread cleanup = new Thread(client::close, "weq-network-close"); cleanup.setDaemon(true); cleanup.start(); }
    }
    private void clearComputer() {
        closeWeb();
        generation++;
        main.removeCallbacks(approvalPoll); endpoint = null; token = null; fingerprint = null; connectionRoutes = null; claimID = null; paired = false; restoring = false;
        computerState.setText("未配对"); detail.setText(""); error.setText(""); busy = false;
    }
    private void pair() {
        if (busy) return;
        try {
            Invitation link = Invitation.parse(invitation.getText().toString());
            if (link.multiRoute) {
                if (link.authKey != null && testControl != null) throw new Exception("测试网络不接受正式入网密钥");
                startMulti(new org.json.JSONArray(link.endpoints).toString(), link.fingerprint, link.authKey, () -> claim(link)); return;
            }
            if (link.fingerprint != null) { startDirect(link.endpoint, link.fingerprint, () -> claim(link)); return; }
            if (link.authKey != null) {
                if (testControl != null) throw new Exception("测试网络不接受正式入网密钥");
                        if (!visible || link.expiresAt <= System.currentTimeMillis()) { invitation.setText(""); error.setText("邀请已过期，请重新生成"); return; }
                        stopNetwork(true); enabled = true; enrolling = link; enrollmentDeadline = SystemClock.elapsedRealtime() + 45000;
                        startNetwork(link.authKey);
                return;
            }
            claim(link);
        } catch (Exception e) { error.setText("配对链接无效或已过期，请重新生成；旧版邀请需先连接网络"); }
    }
    private void startDirect(String address, String pin, Runnable next) {
        stopNetwork(true); busy = true; final int revision = generation; render();
        worker.execute(() -> {
            try {
                Client client = Androidnet.newDirectClient(address, pin);
                main.post(() -> {
                    if (revision != generation || !visible) { closeClient(client); return; }
                    node = client; fingerprint = pin; online = true; busy = false; next.run();
                });
            } catch (Exception e) { fail(revision, "无法创建连接，请重新扫描二维码"); }
        });
    }
    private void startMulti(String routes, String pin, String authKey, Runnable next) {
        stopNetwork(true); busy = true; final int revision = generation; render();
        worker.execute(() -> {
            try {
                Future<?> pendingClose = closing;
                if (pendingClose != null) pendingClose.get();
                go.Seq.setContext(getApplicationContext());
                Androidnet.setInterfaces(interfaceSnapshot());
                String base = new java.io.File(getNoBackupFilesDir(), "tailnet").getAbsolutePath();
                String directory = authKey != null ? Androidnet.authStateDir(base, authKey) : networkDirectory != null ? networkDirectory : base;
                if (revision != generation || !visible) return;
                Client client = Androidnet.newMultiClient(directory, routes, pin, authKey == null ? "" : authKey);
                main.post(() -> {
                    if (revision != generation || !visible) { closeClient(client); return; }
                    networkDirectory = directory;
                    if (authKey != null) getPreferences(MODE_PRIVATE).edit().putString("networkState", new java.io.File(directory).getName()).apply();
                    node = client; fingerprint = pin; connectionRoutes = routes; online = true; busy = false; next.run();
                });
            } catch (Exception e) { fail(revision, "无法连接电脑，请检查局域网、Tailscale 服务或重新生成包含 Key 的配对码"); }
        });
    }
    private boolean restoreComputer() {
        if (busy || testControl != null || invitation.length() > 0) return false;
        try {
            JSONObject saved = ConnectionStore.load(this);
            if (saved == null) return false;
            rememberedComputer = true;
            String address = saved.getString("endpoint"), credential = saved.getString("token"), pin = saved.optString("fingerprint", "");
            if (!credential.matches("[a-f0-9]{64}")) throw new Exception("电脑凭据无效");
            Runnable resume = () -> { endpoint = address; token = credential; paired = true; restoring = true; computerState.setText("正在连接电脑"); verify(); };
            org.json.JSONArray routes = saved.optJSONArray("endpoints");
            if (routes != null) {
                if (routes.length() == 0 || !address.equals(routes.getString(0))) throw new Exception("电脑地址无效");
                startMulti(routes.toString(), pin, null, resume);
            }
            else if (!pin.isEmpty()) startDirect(address, pin, resume);
            else { endpoint = address; token = credential; paired = true; restoring = true; enabled = true; startNetwork(); }
            return true;
        } catch (Exception e) { error.setText("无法读取保存的电脑凭据，请重新配对"); return false; }
    }
    private void claim(Invitation link) {
        if (!online || node == null) { error.setText("此邀请不含入网密钥，请先连接电脑所在的网络"); return; }
        try {
            endpoint = link.endpoint; token = Invitation.credential();
            invitation.setText("");
            JSONObject body = new JSONObject().put("invitation", link.secret).put("name", "WeQ Remote Android").put("tokenHash", Invitation.hash(token)).put("scope", "web:access");
            busy = true; error.setText(""); render();
            final Client client = node; final int revision = generation; final String address = endpoint;
            worker.execute(() -> {
                try {
                    JSONObject response = response(client.request(address, "/v1/pair", "POST", "", body.toString()));
                    String id = response.getString("id"), code = response.getString("code"); long expiry = response.getLong("expiresAt");
                    if (!id.matches("[a-f0-9-]{36}") || !code.matches("[0-9]{6}") || expiry <= System.currentTimeMillis() || expiry > System.currentTimeMillis() + 180000) throw new Exception("电脑返回了不兼容的数据");
                    main.post(() -> {
                        if (revision != generation) return;
                        claimID = id; expiresAt = expiry; busy = false; invitation.setText(""); invitation.clearFocus();
                        ((InputMethodManager)getSystemService(INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(invitation.getWindowToken(), 0);
                        computerState.setText("等待电脑批准"); detail.setText("校验码  " + code); render(); pollApproval();
                    });
                } catch (Exception e) { fail(revision, e.getMessage()); }
            });
        } catch (Exception e) { error.setText("配对失败，请重试"); }
    }
    private void pollApproval() {
        if (claimID == null || node == null || paired) return;
        if (System.currentTimeMillis() >= expiresAt) { clearComputer(); error.setText("配对确认已超时，请重新生成邀请"); render(); return; }
        final Client client = node; final int revision = generation; final String id = claimID, address = endpoint, credential = token;
        worker.execute(() -> {
            try {
                JSONObject approval = response(client.request(address, "/v1/pair/" + id, "GET", credential, ""));
                if (!id.equals(approval.getString("id")) || !"web:access".equals(approval.getString("scope"))) throw new Exception("电脑返回了不兼容的数据，请升级电脑端");
                main.post(() -> { if (revision != generation || !id.equals(claimID)) return; if (approval.optBoolean("approved")) {
                    try { if (!BuildConfig.TESTING || fingerprint != null) { ConnectionStore.save(this, endpoint, token, fingerprint, connectionRoutes); rememberedComputer = true; } paired = true; openWeb(); }
                    catch (Exception e) { fail(revision, "无法保存电脑凭据，请重试"); }
                } else main.postDelayed(approvalPoll, 1500); });
            } catch (Exception e) { fail(revision, e.getMessage()); }
        });
    }
    private void verify() {
        if (node == null || !paired || busy) return;
        final Client client = node; final int revision = generation; final String address = endpoint, credential = token;
        busy = true; error.setText(""); render();
        worker.execute(() -> {
            try {
                long started = SystemClock.elapsedRealtime();
                Androidnet.setInterfaces(interfaceSnapshot());
                JSONObject status = response(client.request(address, "/v1/status", "GET", credential, ""));
                if (!"WeQ Remote".equals(status.getString("product")) || status.getInt("protocol") != 1 || !"status:read".equals(status.getString("scope")) || !status.getBoolean("online")) throw new Exception("电脑返回了不兼容的数据");
                long elapsed = SystemClock.elapsedRealtime() - started;
                boolean webReady = client.hasWeb();
                main.post(() -> { if (revision != generation || !credential.equals(token)) return; busy = false; computerState.setText("电脑在线"); detail.setText("地址  " + address + "\n请求耗时  " + elapsed + " ms\n最近验证  " + DateFormat.getTimeInstance().format(new Date())); if (webNotice != null) webNotice.setVisibility(View.GONE); render(); if (restoring || webView != null && !webReady) { restoring = false; if (visible) openWeb(); } });
            } catch (Exception e) { fail(revision, e.getMessage()); }
        });
    }
    private void openWeb() {
        final Client client = node; final int revision = generation;
        final String address = endpoint, credential = token, localSecret = Invitation.credential();
        busy = true; render();
        worker.execute(() -> {
            try {
                final String origin = client.openWeb(address, credential, localSecret);
                main.post(() -> {
                    if (revision != generation || !visible) return;
                    busy = false;
                    android.webkit.CookieManager cookies = android.webkit.CookieManager.getInstance();
                    cookies.removeAllCookies(ignored -> {
                        if (revision != generation || !visible) return;
                        cookies.setCookie(origin, "weq_remote_local=" + localSecret + "; HttpOnly; SameSite=Strict; Path=/", accepted -> {
                            if (revision != generation || !visible) return;
                            if (webView != null) { webView.stopLoading(); webView.destroy(); }
                            webView = new android.webkit.WebView(this);
                            android.webkit.WebSettings settings = webView.getSettings();
                            settings.setJavaScriptEnabled(true); settings.setDomStorageEnabled(true);
                            settings.setAllowFileAccess(false); settings.setAllowContentAccess(false);
                            settings.setMixedContentMode(android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW);
                            cookies.setAcceptThirdPartyCookies(webView, false);
                            webView.setWebViewClient(new android.webkit.WebViewClient() {
                                private boolean allowed(Uri url) { return "http".equals(url.getScheme()) && "127.0.0.1".equals(url.getHost()) && url.getPort() == Uri.parse(origin).getPort(); }
                                @Override public boolean shouldOverrideUrlLoading(android.webkit.WebView view, android.webkit.WebResourceRequest request) { return !allowed(request.getUrl()); }
                                @Override public android.webkit.WebResourceResponse shouldInterceptRequest(android.webkit.WebView view, android.webkit.WebResourceRequest request) {
                                    if (allowed(request.getUrl())) return null;
                                    return new android.webkit.WebResourceResponse("text/plain", "UTF-8", 403, "Forbidden", java.util.Collections.emptyMap(), new java.io.ByteArrayInputStream(new byte[0]));
                                }
                            });
                            LinearLayout shell = new LinearLayout(this); shell.setOrientation(LinearLayout.VERTICAL);
                            LinearLayout tools = new LinearLayout(this);
                            android.widget.ImageButton close = new android.widget.ImageButton(this); close.setImageResource(android.R.drawable.ic_menu_close_clear_cancel); close.setContentDescription("断开电脑"); close.setOnClickListener(view -> stopNetwork(true));
                            android.widget.ImageButton reload = new android.widget.ImageButton(this); reload.setImageResource(android.R.drawable.ic_popup_sync); reload.setContentDescription("重新加载"); reload.setOnClickListener(view -> webView.reload());
                            android.widget.ImageButton forget = new android.widget.ImageButton(this); forget.setImageResource(android.R.drawable.ic_menu_delete); forget.setContentDescription("删除电脑"); forget.setOnClickListener(view -> forgetComputer());
                            tools.addView(close, new LinearLayout.LayoutParams(dp(48), dp(48))); tools.addView(reload, new LinearLayout.LayoutParams(dp(48), dp(48)));
                            tools.addView(forget, new LinearLayout.LayoutParams(dp(48), dp(48)));
                            shell.addView(tools);
                            webNotice = text("", 14); webNotice.setPadding(dp(16), dp(10), dp(16), dp(10)); webNotice.setVisibility(View.GONE); webNotice.setContentDescription("连接状态"); webNotice.setOnClickListener(view -> verify()); shell.addView(webNotice);
                            shell.addView(webView, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1));
                            if (android.os.Build.VERSION.SDK_INT >= 30) shell.setOnApplyWindowInsetsListener((view, insets) -> {
                                android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.ime());
                                view.setPadding(bars.left, bars.top, bars.right, bars.bottom); return insets;
                            });
                            setContentView(shell); shell.requestApplyInsets(); webView.loadUrl(origin + "/");
                        });
                    });
                });
            } catch (Exception e) { fail(revision, "无法打开 WeQ Web，请检查电脑上的 Web 服务"); }
        });
    }
    private void closeWeb() {
        Client active = node;
        if (active != null) worker.execute(active::closeWeb);
        if (webView == null) return;
        webView.stopLoading(); webView.loadUrl("about:blank"); webView.clearHistory(); webView.clearCache(true); webView.destroy(); webView = null;
        android.webkit.CookieManager.getInstance().removeAllCookies(null);
        setContentView(setupView);
    }
    @Override public void onBackPressed() {
        if (webView != null) { if (webView.canGoBack()) webView.goBack(); else stopNetwork(true); }
        else super.onBackPressed();
    }
    private JSONObject response(String raw) throws Exception {
        JSONObject envelope = new JSONObject(raw); int status = envelope.getInt("status");
        if (status == 401) throw new Exception("设备未授权或授权已被撤销，请重新配对");
        if (status < 200 || status >= 300) throw new Exception("电脑返回 HTTP " + status + "，请检查邀请是否有效");
        return new JSONObject(envelope.getString("body"));
    }
    private void fail(int revision, String message) { main.post(() -> {
        if (revision != generation) return;
        boolean revoked = "设备未授权或授权已被撤销，请重新配对".equals(message);
        if (!revoked && webView != null) {
            busy = false;
            webNotice.setText(message == null ? "连接暂时不可用，正在重试" : message);
            webNotice.setVisibility(View.VISIBLE);
            main.removeCallbacks(reconnectPoll);
            if (visible) main.postDelayed(reconnectPoll, 5000);
            return;
        }
        if (revoked) { ConnectionStore.delete(this); rememberedComputer = false; Androidnet.clearWebCache(); }
        stopNetwork(true); error.setText(message == null ? "连接失败，请重试" : message); render();
        if (!BuildConfig.TESTING && visible) main.postDelayed(reconnectPoll, 5000);
    }); }
    @Override protected void onActivityResult(int request, int result, Intent data) { super.onActivityResult(request, result, data); if (request == 7 && result == RESULT_OK && data != null) { invitation.setText(data.getStringExtra("invitation")); main.post(this::pair); } }
}
