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
import android.widget.TextView;
import java.net.URI;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import org.json.JSONObject;
import androidnet.Androidnet;
import androidnet.Client;
import androidnet.WebGateway;

public final class MainActivity extends Activity {
    private static final String AUTHORIZATION_REJECTED = "设备未授权或授权已被撤销，请重新配对";
    private enum FailureKind {
        PAIRING("配对未完成"), CONNECTION("暂时连不上电脑"), VERIFICATION("无法验证电脑连接"),
        AUTHORIZATION("电脑未授权这台手机"), WEB_LOAD("WeQ 页面加载失败"),
        WEB_STARTUP("WeQ 界面启动失败"), WEB_TIMEOUT("WeQ 页面加载超时");

        final String title;
        FailureKind(String title) { this.title = title; }
        boolean retriesWeb() { return this == WEB_LOAD || this == WEB_STARTUP || this == WEB_TIMEOUT; }
    }

    private static final class HomeFailure {
        final FailureKind kind;
        final String detail;
        HomeFailure(FailureKind kind, String detail) { this.kind = kind; this.detail = detail; }
    }

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
    private boolean updatingConnection;
    private boolean computerVerified;
    private Runnable enrollmentAction;
    private boolean rememberedComputer;
    private long expiresAt;
    private String testControl;
    private String networkDirectory;
    private Invitation enrolling;
    private long enrollmentDeadline;
    private View setupView;
    private android.widget.FrameLayout surface;
    private View webShell, setupMenu, fallbackMenu;
    private boolean openingSavedWeb, webMenuReady, insetWebView;
    private boolean setupProgressFramePending;
    android.webkit.WebView webView;
    private WebFeatures webFeatures;
    TextView networkState, computerState, detail, error, codeView, statusPill;
    private TextView scanLabel;
    private HomeFailure failure;
    private String appVersion = "";
    private ConnectionHealth health = new ConnectionHealth();
    private String connectionRoute = "未选择";
    private android.net.ConnectivityManager connectivity;
    private android.net.ConnectivityManager.NetworkCallback pathMonitor;
    private int healthEpoch, connectionRecovery;
    private boolean eventCheckPending;
    private long lastEventCheck = -5000;
    private final Runnable eventCheck = new Runnable() { public void run() {
        if (!visible || !webLoaded || reconnectPaused) { eventCheckPending = false; return; }
        if (busy) { main.postDelayed(this, 250); return; }
        eventCheckPending = false;
        lastEventCheck = SystemClock.elapsedRealtime();
        verify();
    }};
    private final Runnable healthDeadline = () -> {
        if (!visible || !this.webLoaded) return;
        health.evaluate(SystemClock.elapsedRealtime());
        publishConnectionHealth();
        scheduleConnectionWarning();
    };
    private boolean checkingUpdates;
    EditText invitation;
    Button pairButton, verifyButton, retryButton;
    android.widget.ImageButton disconnectButton, updateButton;
    private LinearLayout connectionActions;
    android.view.View scanButton;
    private LinearLayout pairSection;
    private android.widget.ProgressBar progress;
    private android.widget.ProgressBar developmentRing;
    private TextView developmentCount;
    private DownloadRing downloadRing;
    private WebDownloadProgress webDownload;
    private WebDownloadProgress.Development webDevelopmentProgress;
    private int webStartupRevision;
    private android.widget.ImageView markIcon;
    private android.view.View statusDot;
    private int accentColor, idleDotColor;
    private boolean webLoaded;
    private WebGateway webGateway;
    private String webLoadingStage = "正在准备网页连接";
    private String webStartupProblem;
    private final Runnable webStartupTimeout = () -> {
        if (webLoaded || webGateway == null) return;
        String detail = "最后进度：" + webLoadingStage + "。" + (webStartupProblem == null ? webRecovery() : webStartupProblem);
        if (webView == null) finishWebFailure(FailureKind.WEB_TIMEOUT, detail);
        else failWebLoad(FailureKind.WEB_TIMEOUT, detail);
    };
    private boolean reconnectPaused;
    private final Runnable networkPoll = new Runnable() { public void run() { refreshNetwork(); } };
    private final Runnable approvalPoll = new Runnable() { public void run() { pollApproval(); } };
    private final Runnable reconnectPoll = () -> {
        if (!visible || busy || reconnectPaused) return;
        if (node != null && paired) verify();
        else if (claimID == null) restoreComputer();
    };

    private void startPathMonitor() {
        connectivity = (android.net.ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
        if (connectivity == null || pathMonitor != null) return;
        pathMonitor = new android.net.ConnectivityManager.NetworkCallback() {
            @Override public void onCapabilitiesChanged(android.net.Network network, android.net.NetworkCapabilities capabilities) { main.post(() -> publishNetworkCost()); }
            @Override public void onAvailable(android.net.Network network) { main.post(() -> { if (pathMonitor == this) pathChanged(true); }); }
            @Override public void onLost(android.net.Network network) { main.post(() -> { if (pathMonitor == this) pathChanged(connectivity.getActiveNetwork() != null); }); }
        };
        connectivity.registerDefaultNetworkCallback(pathMonitor);
        android.content.IntentFilter filter = new android.content.IntentFilter(android.net.ConnectivityManager.ACTION_RESTRICT_BACKGROUND_CHANGED);
        if (android.os.Build.VERSION.SDK_INT >= 33) registerReceiver(dataSaverReceiver, filter, android.content.Context.RECEIVER_NOT_EXPORTED);
        else registerReceiver(dataSaverReceiver, filter);
        pathChanged(connectivity.getActiveNetwork() != null);
    }

    private void pathChanged(boolean available) {
        publishNetworkCost();
        if (!visible || pathMonitor == null) return;
        boolean changed = health.networkAvailable != available;
        health.networkChanged(available, SystemClock.elapsedRealtime());
        publishConnectionHealth();
        scheduleConnectionWarning();
        if (changed) requestConnectionCheck(true);
    }

    private final android.content.BroadcastReceiver dataSaverReceiver = new android.content.BroadcastReceiver() {
        @Override public void onReceive(android.content.Context context, android.content.Intent intent) { publishNetworkCost(); }
    };
    private NetworkCost networkCost() {
        android.net.ConnectivityManager manager = (android.net.ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
        if (manager == null || manager.getActiveNetwork() == null) return new NetworkCost(false, false, false);
        boolean metered = manager.isActiveNetworkMetered();
        boolean constrained = metered && manager.getRestrictBackgroundStatus() != android.net.ConnectivityManager.RESTRICT_BACKGROUND_STATUS_DISABLED;
        return new NetworkCost(true, constrained, metered);
    }
    String networkCostJSON() {
        NetworkCost cost = networkCost();
        try { return new org.json.JSONObject().put("state", cost.state()).put("constrained", cost.constrained).put("metered", cost.metered).put("source", "android").toString(); }
        catch (org.json.JSONException impossible) { throw new IllegalStateException(impossible); }
    }
    private void publishNetworkCost() {
        if (webFeatures != null) webFeatures.networkCost(networkCostJSON());
    }
    private volatile String dataSaverMode = "auto";
    void setNetworkPreference(String mode) {
        if (mode.equals("auto") || mode.equals("always") || mode.equals("never")) dataSaverMode = mode;
    }
    private boolean dataSaverEnabled() {
        return networkCost().reduce(dataSaverMode);
    }

    private void requestConnectionCheck(boolean immediately) {
        if (!visible || !webLoaded || reconnectPaused || eventCheckPending) return;
        eventCheckPending = true;
        main.postDelayed(eventCheck, immediately ? 0 : Math.max(0, lastEventCheck + 5000 - SystemClock.elapsedRealtime()));
    }

    private void scheduleConnectionWarning() {
        main.removeCallbacks(healthDeadline);
        if (!visible || !webLoaded) return;
        Long deadline = health.nextDeadline();
        if (deadline != null) main.postDelayed(healthDeadline, Math.max(0, deadline - SystemClock.elapsedRealtime()));
    }

    private void publishConnectionHealth() {
        if (webLoaded && webFeatures != null) webFeatures.connectionState(health.state(), connectionRecovery);
    }

    void receiveConnectionFailure(android.webkit.WebView page) {
        if (webView != page || !webLoaded || !visible || reconnectPaused) return;
        health.failed(SystemClock.elapsedRealtime());
        scheduleConnectionWarning();
        requestConnectionCheck(false);
    }

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        go.Seq.setContext(getApplicationContext());
        try {
            android.content.pm.PackageInfo info = getPackageManager().getPackageInfo(getPackageName(), 0);
            String build = Long.toString(android.os.Build.VERSION.SDK_INT >= 28 ? info.getLongVersionCode() : info.versionCode);
            Androidnet.setDeviceInfo(new JSONObject().put("platform", "android")
                .put("model", android.os.Build.MANUFACTURER + " " + android.os.Build.MODEL)
                .put("osVersion", android.os.Build.VERSION.RELEASE)
                .put("appVersion", info.versionName).put("appBuild", build).toString());
        } catch (Exception ignored) { }
        try {
            Androidnet.setWebStorageDirectory(new java.io.File(getNoBackupFilesDir(), "web-origins").getAbsolutePath());
            Androidnet.setWebCacheDirectory(new java.io.File(getCacheDir(), "web-code").getAbsolutePath());
        }
        catch (Exception ignored) { }
        if (BuildConfig.TESTING && getIntent().getBooleanExtra("isolated_ts_test", false)) {
            String control = getIntent().getStringExtra("test_control");
            try {
                URI uri = new URI(control);
                if ("http".equals(uri.getScheme()) && "127.0.0.1".equals(uri.getHost()) && uri.getPort() > 0 && uri.getUserInfo() == null && "".equals(uri.getPath()) && uri.getQuery() == null && uri.getFragment() == null) testControl = control;
            } catch (Exception ignored) { }
        }
        try { rememberedComputer = ConnectionStore.load(this) != null; } catch (Exception ignored) { }
        buildUI();
        // 网页与连接页都铺满整屏；系统栏透明，连接页自己按 insets 留白。
        if (android.os.Build.VERSION.SDK_INT >= 30) {
            getWindow().setDecorFitsSystemWindows(false);
            getWindow().setStatusBarColor(Color.TRANSPARENT);
            getWindow().setNavigationBarColor(Color.TRANSPARENT);
            boolean dark = (getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;
            android.view.WindowInsetsController controller = getWindow().getInsetsController();
            if (controller != null) {
                int mask = android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS | android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS;
                controller.setSystemBarsAppearance(dark ? 0 : mask, mask);
            }
        }
        if (!BuildConfig.TESTING) getWindow().addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE);
        invitation.setSaveEnabled(false);
        if (testControl == null) {
            String selected = getPreferences(MODE_PRIVATE).getString("networkState", "");
            if (selected.matches("enrolled-[a-f0-9]{64}")) networkDirectory = new java.io.File(new java.io.File(getNoBackupFilesDir(), "tailnet"), selected).getAbsolutePath();
        }
        if (getIntent().getData() != null) invitation.setText(getIntent().getData().toString());
        if (testControl != null) { invitation.setText(getIntent().getStringExtra("test_invitation")); enabled = true; }
        openingSavedWeb = rememberedComputer && invitation.length() == 0 && testControl == null;
        insetWebView = android.os.Build.VERSION.SDK_INT >= 30 && !webViewHandlesSafeArea();
        mountSurface();
        if (!openingSavedWeb) showSetup();
        renderConnectionMenu();
    }

    @Override protected void onResume() {
        super.onResume(); visible = true;
        healthEpoch++;
        health.resume(SystemClock.elapsedRealtime());
        startPathMonitor();
        scheduleConnectionWarning();
        if (webView != null) { webView.onResume(); requestConnectionCheck(true); if (node != null && paired) verify(); else restoreComputer(); return; }
        if (!BuildConfig.TESTING && invitation.length() > 0) { main.post(this::pair); return; }
        if (node == null && !busy && !restoreComputer() && enabled) startNetwork();
    }
    @Override protected void onStop() {
        visible = false;
        healthEpoch++;
        main.removeCallbacks(eventCheck); eventCheckPending = false;
        health.suspend();
        main.removeCallbacks(healthDeadline);
        if (connectivity != null && pathMonitor != null) { connectivity.unregisterNetworkCallback(pathMonitor); unregisterReceiver(dataSaverReceiver); }
        pathMonitor = null;
        main.removeCallbacks(reconnectPoll);
        if (webView == null) {
            HomeFailure previousFailure = failure;
            stopNetwork(false);
            if (previousFailure != null && (previousFailure.kind.retriesWeb() || previousFailure.kind == FailureKind.AUTHORIZATION)) {
                failure = previousFailure;
                render();
            }
        }
        super.onStop();
    }
    @Override protected void onPause() {
        if (webView != null) webView.onPause();
        super.onPause();
    }
    @Override public void onConfigurationChanged(Configuration configuration) {
        super.onConfigurationChanged(configuration);
        // 旋转只重排当前界面，保留 WebView、原生选择器回调和在途下载。
        getWindow().getDecorView().requestApplyInsets();
        if (webView != null) webView.requestApplyInsets();
        if (setupView != null) setupView.requestApplyInsets();
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
        final int accent = dark ? Color.rgb(91, 212, 190) : Color.rgb(5, 122, 109);
        final int pageColor = dark ? Color.rgb(18, 20, 22) : Color.rgb(245, 247, 247);
        final int card = dark ? Color.rgb(30, 34, 35) : Color.WHITE;
        final int border = dark ? Color.rgb(59, 67, 68) : Color.rgb(212, 220, 220);
        final int muted = dark ? Color.rgb(170, 179, 180) : Color.rgb(98, 110, 112);
        final int ink = dark ? Color.rgb(236, 240, 240) : Color.rgb(24, 30, 31);
        final int errorColor = dark ? Color.rgb(255, 160, 150) : Color.rgb(170, 35, 30);
        final int actionText = dark ? Color.rgb(13, 35, 31) : Color.WHITE;
        final int pad = dp(24);
        accentColor = accent;
        idleDotColor = dark ? Color.rgb(140, 148, 149) : Color.rgb(176, 183, 184);

        // 全屏三段式首页：顶部状态条、居中状态区、贴近拇指的底部操作坞。
        android.widget.FrameLayout page = new android.widget.FrameLayout(this);
        page.setBackgroundColor(pageColor);
        setupView = page;
        android.widget.ScrollView scroll = new android.widget.ScrollView(this);
        scroll.setFillViewport(true);
        page.addView(scroll, new android.widget.FrameLayout.LayoutParams(Math.min(getResources().getDisplayMetrics().widthPixels, dp(496)), -1, android.view.Gravity.TOP | android.view.Gravity.CENTER_HORIZONTAL));
        final LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(pad, dp(8), pad, dp(10));
        scroll.addView(content, new android.widget.ScrollView.LayoutParams(-1, -2));
        page.setOnApplyWindowInsetsListener((view, insets) -> {
            android.graphics.Rect bars = WindowInsetsHelper.contentInsets(insets);
            scroll.setPadding(bars.left, bars.top, bars.right, bars.bottom);
            return insets;
        });
        page.requestApplyInsets();

        LinearLayout topBar = new LinearLayout(this);
        topBar.setOrientation(LinearLayout.HORIZONTAL);
        topBar.setGravity(android.view.Gravity.CENTER_VERTICAL);
        android.widget.ImageView brandMark = new android.widget.ImageView(this);
        brandMark.setImageResource(getResources().getIdentifier("ic_computer", "drawable", getPackageName()));
        brandMark.setColorFilter(accent);
        brandMark.setPadding(dp(6), dp(6), dp(6), dp(6));
        brandMark.setBackground(background(Color.argb(30, Color.red(accent), Color.green(accent), Color.blue(accent)), Color.TRANSPARENT, dp(9)));
        brandMark.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        topBar.addView(brandMark, new LinearLayout.LayoutParams(dp(30), dp(30)));
        TextView brand = text("WeQ Remote", 16);
        brand.setTypeface(null, android.graphics.Typeface.BOLD);
        brand.setTextColor(ink);
        brand.setPadding(dp(10), 0, 0, 0);
        brand.setSingleLine(true);
        brand.setAutoSizeTextTypeUniformWithConfiguration(12, 16, 1, android.util.TypedValue.COMPLEX_UNIT_SP);
        topBar.addView(brand, new LinearLayout.LayoutParams(0, -2, 1f));
        LinearLayout statusChip = new LinearLayout(this);
        statusChip.setOrientation(LinearLayout.HORIZONTAL);
        statusChip.setGravity(android.view.Gravity.CENTER_VERTICAL);
        statusChip.setPadding(dp(12), dp(6), dp(12), dp(6));
        statusChip.setBackground(background(card, border, dp(100)));
        statusDot = new android.view.View(this);
        statusDot.setBackground(oval(idleDotColor));
        statusChip.addView(statusDot, new LinearLayout.LayoutParams(dp(6), dp(6)));
        statusPill = text("未配对", 12);
        statusPill.setTextColor(muted);
        statusPill.setPadding(dp(6), 0, 0, 0);
        statusChip.addView(statusPill);
        topBar.addView(statusChip);
        setupMenu = connectionMenuButton("更多", accent);
        topBar.addView(setupMenu, new LinearLayout.LayoutParams(dp(44), dp(44)));
        content.addView(topBar);

        android.widget.FrameLayout hero = new android.widget.FrameLayout(this);
        content.addView(hero, new LinearLayout.LayoutParams(-1, -2, 1f));
        LinearLayout heroColumn = new LinearLayout(this);
        heroColumn.setOrientation(LinearLayout.VERTICAL);
        heroColumn.setGravity(android.view.Gravity.CENTER_HORIZONTAL);
        hero.addView(heroColumn, new android.widget.FrameLayout.LayoutParams(-1, -2, android.view.Gravity.CENTER));
        android.widget.FrameLayout markFrame = new android.widget.FrameLayout(this);
        heroColumn.addView(markFrame, new LinearLayout.LayoutParams(-1, dp(150)));
        android.view.View disc = new android.view.View(this);
        disc.setBackground(oval(Color.argb(26, Color.red(accent), Color.green(accent), Color.blue(accent))));
        markFrame.addView(disc, new android.widget.FrameLayout.LayoutParams(dp(108), dp(108), android.view.Gravity.CENTER));
        downloadRing = new DownloadRing(this, accent);
        markFrame.addView(downloadRing, new android.widget.FrameLayout.LayoutParams(dp(142), dp(142), android.view.Gravity.CENTER));
        markIcon = new android.widget.ImageView(this);
        markIcon.setImageResource(getResources().getIdentifier("ic_computer", "drawable", getPackageName()));
        markIcon.setColorFilter(accent);
        markIcon.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        markFrame.addView(markIcon, new android.widget.FrameLayout.LayoutParams(dp(44), dp(44), android.view.Gravity.CENTER));
        progress = new android.widget.ProgressBar(this);
        progress.setIndeterminate(true);
        progress.setIndeterminateTintList(android.content.res.ColorStateList.valueOf(accent));
        progress.setVisibility(View.GONE);
        markFrame.addView(progress, new android.widget.FrameLayout.LayoutParams(dp(44), dp(44), android.view.Gravity.CENTER));
        developmentRing = new android.widget.ProgressBar(this);
        developmentRing.setIndeterminate(true);
        developmentRing.setIndeterminateTintList(android.content.res.ColorStateList.valueOf(accent));
        developmentRing.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        developmentRing.setVisibility(View.GONE);
        markFrame.addView(developmentRing, new android.widget.FrameLayout.LayoutParams(dp(138), dp(138), android.view.Gravity.CENTER));
        developmentCount = text("", 18);
        developmentCount.setTextColor(accent);
        developmentCount.setGravity(android.view.Gravity.CENTER);
        developmentCount.setMaxLines(2);
        developmentCount.setAutoSizeTextTypeUniformWithConfiguration(11, 18, 1, android.util.TypedValue.COMPLEX_UNIT_SP);
        developmentCount.setVisibility(View.GONE);
        markFrame.addView(developmentCount, new android.widget.FrameLayout.LayoutParams(dp(104), dp(60), android.view.Gravity.CENTER));
        computerState = text("连接电脑", 22);
        computerState.setTypeface(null, android.graphics.Typeface.BOLD);
        computerState.setTextColor(ink);
        computerState.setGravity(android.view.Gravity.CENTER);
        LinearLayout.LayoutParams titleParams = new LinearLayout.LayoutParams(-1, -2);
        titleParams.topMargin = dp(18);
        heroColumn.addView(computerState, titleParams);
        detail = text("", 14);
        detail.setTextColor(muted);
        detail.setGravity(android.view.Gravity.CENTER);
        LinearLayout.LayoutParams detailParams = new LinearLayout.LayoutParams(-1, -2);
        detailParams.topMargin = dp(8);
        heroColumn.addView(detail, detailParams);
        codeView = text("", 34);
        codeView.setTypeface(android.graphics.Typeface.MONOSPACE);
        codeView.setTextColor(ink);
        codeView.setGravity(android.view.Gravity.CENTER);
        codeView.setVisibility(View.GONE);
        LinearLayout.LayoutParams codeParams = new LinearLayout.LayoutParams(-2, -2);
        codeParams.topMargin = dp(14);
        heroColumn.addView(codeView, codeParams);
        error = text("", 13);
        error.setTextColor(errorColor);
        error.setGravity(android.view.Gravity.CENTER);
        LinearLayout.LayoutParams errorParams = new LinearLayout.LayoutParams(-1, -2);
        errorParams.topMargin = dp(10);
        heroColumn.addView(error, errorParams);
        verifyButton = button("验证连通", this::verify);
        verifyButton.setVisibility(View.GONE);
        LinearLayout.LayoutParams verifyParams = new LinearLayout.LayoutParams(-2, -2);
        verifyParams.topMargin = dp(12);
        heroColumn.addView(verifyButton, verifyParams);

        LinearLayout dock = new LinearLayout(this);
        dock.setOrientation(LinearLayout.VERTICAL);
        content.addView(dock, new LinearLayout.LayoutParams(-1, -2));

        pairSection = new LinearLayout(this);
        pairSection.setOrientation(LinearLayout.VERTICAL);
        dock.addView(pairSection, new LinearLayout.LayoutParams(-1, -2));
        LinearLayout scan = new LinearLayout(this);
        scan.setOrientation(LinearLayout.HORIZONTAL);
        scan.setGravity(android.view.Gravity.CENTER);
        scan.setBackground(new android.graphics.drawable.RippleDrawable(android.content.res.ColorStateList.valueOf(0x30ffffff), background(accent, accent, dp(16)), null));
        scan.setContentDescription("扫码");
        scan.setFocusable(true);
        scan.setClickable(true);
        android.widget.ImageView scanIcon = new android.widget.ImageView(this);
        scanIcon.setImageResource(getResources().getIdentifier("ic_scan", "drawable", getPackageName()));
        scanIcon.setColorFilter(actionText);
        scanIcon.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        scan.addView(scanIcon, new LinearLayout.LayoutParams(dp(22), dp(22)));
        scanLabel = text("扫码连接", 17);
        scanLabel.setTypeface(null, android.graphics.Typeface.BOLD);
        scanLabel.setTextColor(actionText);
        scanLabel.setPadding(dp(12), 0, 0, 0);
        scan.addView(scanLabel);
        scan.setOnClickListener(v -> scanConnection());
        scanButton = scan;
        pairSection.addView(scan, new LinearLayout.LayoutParams(-1, dp(58)));
        LinearLayout input = new LinearLayout(this);
        input.setGravity(android.view.Gravity.CENTER_VERTICAL);
        input.setPadding(dp(14), dp(4), dp(6), dp(4));
        input.setBackground(background(card, border, dp(16)));
        LinearLayout.LayoutParams inputParams = new LinearLayout.LayoutParams(-1, -2);
        inputParams.topMargin = dp(12);
        pairSection.addView(input, inputParams);
        android.widget.ImageView linkIcon = new android.widget.ImageView(this);
        linkIcon.setImageResource(getResources().getIdentifier("ic_link", "drawable", getPackageName()));
        linkIcon.setColorFilter(muted);
        linkIcon.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        input.addView(linkIcon, new LinearLayout.LayoutParams(dp(16), dp(16)));
        invitation = new EditText(this);
        invitation.setHint("粘贴配对链接");
        invitation.setTextSize(15);
        invitation.setBackgroundColor(Color.TRANSPARENT);
        invitation.setSingleLine(true);
        invitation.setMinHeight(dp(48));
        invitation.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_URI | android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        invitation.setImeOptions(android.view.inputmethod.EditorInfo.IME_ACTION_GO);
        invitation.setOnEditorActionListener((view, action, event) -> { if (action == android.view.inputmethod.EditorInfo.IME_ACTION_GO) { pair(); return true; } return false; });
        invitation.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO);
        invitation.setPadding(dp(8), 0, 0, 0);
        input.addView(invitation, new LinearLayout.LayoutParams(0, -2, 1));
        pairButton = new Button(this);
        pairButton.setText("");
        pairButton.setContentDescription("连接电脑");
        pairButton.setMinHeight(0);
        pairButton.setMinimumHeight(0);
        pairButton.setMinWidth(0);
        pairButton.setMinimumWidth(0);
        pairButton.setPadding(0, 0, 0, 0);
        pairButton.setBackground(new android.graphics.drawable.RippleDrawable(android.content.res.ColorStateList.valueOf(0x30ffffff), oval(accent), null));
        android.graphics.drawable.Drawable playIcon = getDrawable(getResources().getIdentifier("ic_arrow_right", "drawable", getPackageName())).mutate();
        playIcon.setTint(actionText);
        pairButton.setCompoundDrawablesWithIntrinsicBounds(playIcon, null, null, null);
        pairButton.setOnClickListener(view -> pair());
        input.addView(pairButton, new LinearLayout.LayoutParams(dp(48), dp(48)));

        connectionActions = new LinearLayout(this);
        connectionActions.setOrientation(LinearLayout.HORIZONTAL);
        LinearLayout.LayoutParams actionsParams = new LinearLayout.LayoutParams(-1, dp(52));
        actionsParams.topMargin = dp(12);
        dock.addView(connectionActions, actionsParams);
        updateButton = new android.widget.ImageButton(this);
        updateButton.setImageResource(getResources().getIdentifier("ic_scan", "drawable", getPackageName()));
        updateButton.setColorFilter(accent);
        updateButton.setContentDescription("扫码更新连接");
        updateButton.setBackground(new android.graphics.drawable.RippleDrawable(android.content.res.ColorStateList.valueOf(0x22000000), background(card, border, dp(14)), null));
        updateButton.setOnClickListener(view -> scanConnection());
        connectionActions.addView(updateButton, new LinearLayout.LayoutParams(dp(52), dp(52)));

        retryButton = new Button(this);
        retryButton.setText("连接");
        retryButton.setAllCaps(false);
        retryButton.setTextSize(16);
        retryButton.setTypeface(null, android.graphics.Typeface.BOLD);
        retryButton.setTextColor(accent);
        retryButton.setGravity(android.view.Gravity.CENTER);
        retryButton.setBackground(new android.graphics.drawable.RippleDrawable(android.content.res.ColorStateList.valueOf(0x22000000), background(Color.argb(30, Color.red(accent), Color.green(accent), Color.blue(accent)), Color.argb(30, Color.red(accent), Color.green(accent), Color.blue(accent)), dp(14)), null));
        retryButton.setVisibility(View.GONE);
        retryButton.setOnClickListener(view -> {
            if (isConnecting()) { reconnectPaused = true; stopNetwork(true); }
            else retryComputer();
        });
        LinearLayout.LayoutParams retryParams = new LinearLayout.LayoutParams(0, dp(52), 1f);
        retryParams.setMargins(dp(12), 0, dp(12), 0);
        connectionActions.addView(retryButton, retryParams);

        disconnectButton = new android.widget.ImageButton(this);
        disconnectButton.setImageResource(android.R.drawable.ic_menu_delete);
        disconnectButton.setColorFilter(errorColor);
        disconnectButton.setContentDescription("删除电脑");
        disconnectButton.setBackground(new android.graphics.drawable.RippleDrawable(android.content.res.ColorStateList.valueOf(0x22000000), background(card, border, dp(14)), null));
        disconnectButton.setOnClickListener(view -> forgetComputer());
        disconnectButton.setVisibility(View.GONE);
        connectionActions.addView(disconnectButton, new LinearLayout.LayoutParams(dp(52), dp(52)));

        // 网络状态留作连接模型，详情在菜单呈现，不堆在首页。
        networkState = text("Tailscale：未启动", 11);
        networkState.setTextColor(muted);
        networkState.setGravity(android.view.Gravity.CENTER);
        try { appVersion = getPackageManager().getPackageInfo(getPackageName(), 0).versionName; } catch (Exception ignored) { }
        invitation.addTextChangedListener(new android.text.TextWatcher() {
            public void beforeTextChanged(CharSequence value, int start, int count, int after) { }
            public void onTextChanged(CharSequence value, int start, int before, int count) { render(); }
            public void afterTextChanged(android.text.Editable value) { }
        });
        render();
    }
    private TextView text(String value, int size) { TextView view = new TextView(this); view.setText(value); view.setTextSize(size); view.setLineSpacing(dp(3), 1); return view; }
    private android.graphics.drawable.Drawable background(int fill, int border) { return background(fill, border, dp(8)); }
    private android.graphics.drawable.Drawable background(int fill, int border, int radius) {
        GradientDrawable shape = new GradientDrawable(); shape.setColor(fill); shape.setCornerRadius(radius); shape.setStroke(dp(1), border); return shape;
    }
    private android.graphics.drawable.Drawable oval(int fill) {
        GradientDrawable shape = new GradientDrawable(); shape.setShape(GradientDrawable.OVAL); shape.setColor(fill); return shape;
    }
    private Button button(String label, Runnable action) {
        Button button = new Button(this); button.setText(label); button.setAllCaps(false); button.setMinHeight(dp(50)); button.setMaxLines(2);
        int resource = label.startsWith("扫码") ? getResources().getIdentifier("ic_scan", "drawable", getPackageName()) : label.equals("粘贴链接") ? android.R.drawable.ic_menu_edit : label.equals("验证连通") ? android.R.drawable.ic_popup_sync : 0;
        if (resource != 0) { android.graphics.drawable.Drawable icon = getDrawable(resource).mutate(); icon.setTint(button.getCurrentTextColor()); button.setCompoundDrawablesWithIntrinsicBounds(icon, null, null, null); button.setCompoundDrawablePadding(dp(8)); }
        button.setOnClickListener(v -> action.run()); return button;
    }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }

    private android.widget.ImageButton connectionMenuButton(String label, int tint) {
        android.widget.ImageButton button = new android.widget.ImageButton(this);
        button.setImageResource(getResources().getIdentifier("ic_more", "drawable", getPackageName()));
        button.setColorFilter(tint);
        android.util.TypedValue ripple = new android.util.TypedValue();
        if (getTheme().resolveAttribute(android.R.attr.selectableItemBackground, ripple, true))
            button.setBackgroundResource(ripple.resourceId);
        button.setContentDescription(label);
        button.setOnClickListener(view -> showDetailsMenu());
        return button;
    }

    private void mountSurface() {
        surface = new android.widget.FrameLayout(this);
        surface.setBackgroundColor(webBackgroundColor());
        boolean dark = (getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;
        fallbackMenu = connectionMenuButton("连接菜单", dark ? Color.WHITE : Color.BLACK);
        surface.addView(fallbackMenu, new android.widget.FrameLayout.LayoutParams(dp(44), dp(44), android.view.Gravity.TOP | android.view.Gravity.RIGHT));
        surface.setOnApplyWindowInsetsListener((view, insets) -> { layoutFallbackMenu(insets); return insets; });
        surface.addOnLayoutChangeListener((view, l, t, r, b, oldL, oldT, oldR, oldB) -> layoutFallbackMenu(view.getRootWindowInsets()));
        setContentView(surface);
        surface.requestApplyInsets();
    }

    private void layoutFallbackMenu(WindowInsets insets) {
        android.graphics.Rect bars = new android.graphics.Rect();
        if (insets != null && android.os.Build.VERSION.SDK_INT >= 30)
            bars = WindowInsetsHelper.webInsets(insets);
        int width = surface.getWidth() - (insetWebView ? bars.left + bars.right : 0);
        boolean single = width <= dp(760) && getResources().getConfiguration().orientation != Configuration.ORIENTATION_LANDSCAPE;
        android.widget.FrameLayout.LayoutParams params = (android.widget.FrameLayout.LayoutParams) fallbackMenu.getLayoutParams();
        int top = bars.top + dp(single ? 6 : 0), right = bars.right + dp(12);
        if (top != params.topMargin || right != params.rightMargin) {
            params.topMargin = top;
            params.rightMargin = right;
            fallbackMenu.setLayoutParams(params);
        }
    }

    private void showSetup() {
        if (setupView.getParent() == null)
            surface.addView(setupView, webShell == null ? 0 : 1, new android.widget.FrameLayout.LayoutParams(-1, -1));
    }

    private boolean hasWebRecovery() { return openingSavedWeb || webGateway != null || webView != null || hasWebFailure(); }

    private void renderConnectionMenu() {
        boolean fallback = hasWebRecovery() && !(webLoaded && webMenuReady);
        fallbackMenu.setVisibility(fallback ? View.VISIBLE : View.GONE);
        setupMenu.setVisibility(fallback ? View.INVISIBLE : View.VISIBLE);
    }

    private static void setTextIfChanged(TextView view, String text) {
        if (!android.text.TextUtils.equals(view.getText(), text)) view.setText(text);
    }

    private void renderSetupProgress() {
        if (setupProgressFramePending) return;
        setupProgressFramePending = true;
        // 网页资源可以连续上报，同一帧只绘制最后一次进度。
        android.view.Choreographer.getInstance().postFrameCallback(frameTime -> {
            setupProgressFramePending = false;
            if (!webLoaded && !isDestroyed() && !isFinishing()) render();
        });
    }

    private void render() {
        if (fallbackMenu != null) renderConnectionMenu();
        boolean loading = isConnecting();
        boolean canPair = claimID == null && !rememberedComputer && !paired;
        pairSection.setVisibility(canPair ? View.VISIBLE : View.GONE);
        scanButton.setEnabled(!busy);
        boolean needsAuthorization = failure != null && failure.kind == FailureKind.AUTHORIZATION;
        setTextIfChanged(scanLabel, needsAuthorization ? "重新配对" : "扫码连接");
        scanButton.setContentDescription(needsAuthorization ? "重新配对" : "扫码");
        pairButton.setEnabled(!busy && claimID == null && invitation.length() > 0);
        pairButton.setVisibility(invitation.length() > 0 ? View.VISIBLE : View.GONE);
        verifyButton.setVisibility(paired && BuildConfig.TESTING ? View.VISIBLE : View.GONE);
        verifyButton.setEnabled(!busy);
        boolean measured = loading && webView != null && !webLoaded && webDownload != null && webDownload.showsRing();
        boolean development = loading && !webLoaded && webDevelopmentProgress != null && webDownload == null;
        downloadRing.update(measured ? webDownload : null);
        progress.setVisibility(loading && !measured && !development ? View.VISIBLE : View.GONE);
        developmentRing.setVisibility(development ? View.VISIBLE : View.GONE);
        developmentCount.setVisibility(development ? View.VISIBLE : View.GONE);
        if (development) setTextIfChanged(developmentCount, "资源加载\n" + webDevelopmentProgress.completed + " 项");
        markIcon.setVisibility(loading ? View.INVISIBLE : View.VISIBLE);
        connectionActions.setVisibility(paired || rememberedComputer || loading ? View.VISIBLE : View.GONE);
        updateButton.setVisibility(rememberedComputer ? View.VISIBLE : View.GONE);
        retryButton.setVisibility(rememberedComputer || loading ? View.VISIBLE : View.GONE);
        setTextIfChanged(retryButton, loading ? "停止" : failure == null ? "连接" : failure.kind.retriesWeb() ? "重试打开" : "重新连接");
        retryButton.setEnabled(true);
        disconnectButton.setVisibility(paired || claimID != null || rememberedComputer ? View.VISIBLE : View.GONE);
        codeView.setVisibility(claimID != null ? View.VISIBLE : View.GONE);
        String status = statusText();
        if (!android.text.TextUtils.equals(statusPill.getText(), status)) {
            statusPill.setText(status);
            ((GradientDrawable) statusDot.getBackground()).setColor(status.equals("连接中") || claimID != null ? accentColor : idleDotColor);
        }
        setTextIfChanged(computerState, heroTitle());
        setTextIfChanged(detail, heroDetail());
        detail.setVisibility(detail.length() > 0 ? View.VISIBLE : View.GONE);
        setTextIfChanged(error, failure == null ? "" : failure.detail);
        error.setVisibility(failure == null ? View.GONE : View.VISIBLE);
    }

    private boolean isConnecting() { return busy || claimID != null || ((paired || webView != null) && !webLoaded); }

    private boolean hasWebFailure() { return failure != null && failure.kind.retriesWeb(); }

    private void retryComputer() {
        reconnectPaused = false;
        restoreComputer();
    }

    private void showFailure(FailureKind kind, String detail) {
        failure = new HomeFailure(kind, detail);
        render();
    }

    private void scanConnection() {
        reconnectPaused = true;
        stopNetwork(true);
        startActivityForResult(new Intent(this, ScannerActivity.class), 7);
    }

    private String heroTitle() {
        if (claimID != null) return "等待电脑确认";
        if (!webLoaded && (paired || webView != null)) return webLoadingStage;
        if (busy) return paired ? "正在验证电脑授权" : "正在连接电脑";
        if (failure != null) return failure.kind.title;
        if (rememberedComputer) return "我的电脑";
        return "连接电脑";
    }

    private String heroDetail() {
        if (claimID != null) return "在电脑上核对校验码，并允许这台手机访问";
        if (!webLoaded && (paired || webView != null)) {
            if (webDownload != null) return webDownload.detail();
            if (webDevelopmentProgress != null) return webDevelopmentProgress.detail();
            return computerHost("页面准备好后自动进入");
        }
        if (busy) return computerHost("正在准备与电脑的连接");
        if (failure != null) return computerHost("");
        if (rememberedComputer) return computerHost("打开后会自动连接上次的电脑");
        return "在电脑上的 WeQ 生成配对码，扫码或粘贴链接即可连接";
    }

    private String computerHost(String fallback) {
        try { String host = new URI(endpoint).getHost(); return host == null ? fallback : host; }
        catch (Exception ignored) { return fallback; }
    }

    private String statusText() {
        if (claimID != null) return "等待批准";
        if (rememberedComputer || paired) return "已配对";
        return isConnecting() ? "连接中" : "未配对";
    }

    private void forgetComputer() {
        new android.app.AlertDialog.Builder(this).setTitle("删除电脑？")
            .setMessage("将清除本机保存的电脑连接，下次需要重新扫码并在电脑上批准。电脑上的设备授权不会撤销。")
            .setNegativeButton("取消", null)
            .setPositiveButton("删除电脑", (dialog, which) -> {
                reconnectPaused = true;
                closeWeb(); ConnectionStore.delete(this); rememberedComputer = false; Androidnet.clearWebCache(); stopNetwork(true);
            }).show();
    }

    void showConnectionMenu() {
        if (webView == null || !webLoaded || isFinishing()) return;
        showDetailsMenu();
    }
    private String connectionDetails() {
        String checked = health.checkedAt == 0 ? "尚未验证" : java.text.DateFormat.getTimeInstance().format(new java.util.Date(health.checkedAt));
        String latency = health.latency == null ? "—" : health.latency + " ms";
        String build = "未知";
        try { build = Long.toString(android.os.Build.VERSION.SDK_INT >= 28 ? getPackageManager().getPackageInfo(getPackageName(), 0).getLongVersionCode() : getPackageManager().getPackageInfo(getPackageName(), 0).versionCode); } catch (Exception ignored) { }
        return "连接：" + (node == null ? "未连接" : health.status()) + "\n电脑：" + (endpoint == null ? "未选择" : endpoint)
            + "\n连接方式：" + connectionRoute + "\n" + networkState.getText()
            + "\n最近成功：" + checked + "\n请求耗时：" + latency
            + "\nWeQ Remote " + appVersion + " (" + build + ") · Android " + android.os.Build.VERSION.RELEASE;
    }
    private void showDetailsMenu() {
        if (!visible || isFinishing() || isDestroyed() || !getWindow().getDecorView().isAttachedToWindow()) return;
        String[] actions = hasWebRecovery() ? new String[]{"立即检查", "检查更新", webLoaded ? "重新加载" : "重试打开", "断开连接"}
            : paired ? new String[]{"立即检查", "检查更新"} : new String[]{"检查更新"};
        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(dp(24), dp(12), dp(24), dp(8));
        TextView details = text(connectionDetails(), 14);
        details.setTextIsSelectable(true);
        content.addView(details, new LinearLayout.LayoutParams(-1, -2));
        android.widget.Switch prerelease = new android.widget.Switch(this);
        prerelease.setText("检查测试版");
        prerelease.setMinHeight(dp(48));
        prerelease.setChecked(getPreferences(MODE_PRIVATE).getBoolean("checkPrerelease", false));
        prerelease.setEnabled(!checkingUpdates);
        prerelease.setOnCheckedChangeListener((view, enabled) -> getPreferences(MODE_PRIVATE).edit().putBoolean("checkPrerelease", enabled).apply());
        content.addView(prerelease, new LinearLayout.LayoutParams(-1, -2));
        android.widget.ScrollView scroll = new android.widget.ScrollView(this);
        scroll.addView(content);
        android.app.AlertDialog menu = new android.app.AlertDialog.Builder(this).setTitle("连接详情")
            .setView(scroll).setNegativeButton("完成", null).create();
        for (String action : actions) {
            content.addView(button(action, () -> {
                menu.dismiss();
                if ("立即检查".equals(action)) { if (node != null && paired) verify(); else retryComputer(); }
                else if ("检查更新".equals(action)) checkUpdates();
                else if ("重新加载".equals(action) || "重试打开".equals(action)) {
                    if (webView != null) reloadWeb();
                    else { stopNetwork(true); retryComputer(); }
                }
                else {
                    reconnectPaused = true;
                    stopNetwork(true);
                    if (android.animation.ValueAnimator.areAnimatorsEnabled()) {
                        setupView.setAlpha(0);
                        setupView.animate().alpha(1).setDuration(180).start();
                    }
                }
            }), new LinearLayout.LayoutParams(-1, -2));
        }
        menu.show();
    }

    private void checkUpdates() {
        if (checkingUpdates || !visible || isFinishing() || isDestroyed()) return;
        checkingUpdates = true;
        final boolean includePrerelease = getPreferences(MODE_PRIVATE).getBoolean("checkPrerelease", false);
        android.app.AlertDialog progressDialog = new android.app.AlertDialog.Builder(this)
            .setTitle("检查更新").setMessage("正在检查更新…").setNegativeButton("关闭", null).show();
        worker.execute(() -> {
            String message;
            java.util.List<UpdateMirrors.Candidate> downloads = java.util.Collections.emptyList();
            try {
                ReleaseVersion current = ReleaseVersion.parse(appVersion);
                if (current == null) throw new Exception();
                org.json.JSONArray sources;
                try (java.io.InputStream stream = getAssets().open("update-mirrors.json")) {
                    java.io.ByteArrayOutputStream data = new java.io.ByteArrayOutputStream();
                    byte[] buffer = new byte[1024]; int count;
                    while ((count = stream.read(buffer)) != -1) data.write(buffer, 0, count);
                    sources = new org.json.JSONArray(data.toString("UTF-8"));
                }
                java.util.List<String> prefixes = new java.util.ArrayList<>();
                for (int i = 0; i < sources.length(); i++) prefixes.add(sources.getString(i));
                main.post(() -> { if (progressDialog.isShowing()) progressDialog.setMessage("正在读取发布版本…"); });
                org.json.JSONArray releases = new org.json.JSONArray(UpdateMirrors.releaseJSON());
                java.util.List<ReleaseCatalog.Entry> entries = new java.util.ArrayList<>();
                for (int i = 0; i < releases.length(); i++) {
                    JSONObject release = releases.getJSONObject(i);
                    org.json.JSONArray assets = release.getJSONArray("assets");
                    boolean hasManifest = false;
                    for (int j = 0; j < assets.length(); j++) if ("SHA256SUMS".equals(assets.getJSONObject(j).getString("name"))) hasManifest = true;
                    entries.add(new ReleaseCatalog.Entry(release.getString("tag_name"), release.getBoolean("draft"), release.getBoolean("prerelease"), !release.isNull("published_at"), hasManifest));
                }
                ReleaseCatalog release = ReleaseCatalog.select(entries, includePrerelease);
                main.post(() -> { if (progressDialog.isShowing()) progressDialog.setMessage("测速中（" + prefixes.size() + " 个源）"); });
                java.util.List<UpdateMirrors.Candidate> ranked = UpdateMirrors.resolve(prefixes, release, !dataSaverEnabled());
                UpdateMirrors.Candidate best = ranked.get(0);
                ReleaseVersion latest = best.manifest.version;
                int order = latest.compareTo(current);
                if (order > 0) downloads = ranked;
                message = (order > 0 ? "发现新版本 v" + latest.text + "\n当前 v" + appVersion + " → v" + latest.text : order == 0 ? "已是最新版本\n当前 v" + appVersion : "当前 v" + appVersion + "，最新发布为 v" + latest.text)
                    + "\n已自动选择加速站 " + best.label() + "（已测速）";
            } catch (Exception failure) {
                message = "检查更新失败，无法读取发布版本或连接加速站，请检查网络后重试。";
            }
            final String result = message;
            final java.util.List<UpdateMirrors.Candidate> available = downloads;
            main.post(() -> {
                checkingUpdates = false;
                if (isFinishing() || isDestroyed()) return;
                progressDialog.dismiss();
                if (!visible) return;
                android.app.AlertDialog.Builder dialog = new android.app.AlertDialog.Builder(this).setTitle("检查更新").setMessage(result).setNegativeButton("完成", null);
                if (!available.isEmpty()) dialog.setPositiveButton("下载更新", (view, which) -> openUpdateDownload(available.get(0)));
                if (available.size() > 1) dialog.setNeutralButton("备用下载", (view, which) -> {
                    String[] labels = available.stream().map(UpdateMirrors.Candidate::label).toArray(String[]::new);
                    new android.app.AlertDialog.Builder(this).setTitle("下载源").setItems(labels, (choice, index) -> openUpdateDownload(available.get(index))).setNegativeButton("取消", null).show();
                });
                dialog.show();
            });
        });
    }
    private void openUpdateDownload(UpdateMirrors.Candidate candidate) {
        try { startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(candidate.downloadURL()))); }
        catch (android.content.ActivityNotFoundException missing) { android.widget.Toast.makeText(this, "未找到可用浏览器", android.widget.Toast.LENGTH_LONG).show(); }
    }

    private void reloadWeb() {
        if (webView == null) return;
        if (webGateway != null) webGateway.activateLatest();
        webLoaded = false;
        webMenuReady = false;
        webStartupRevision++;
        webStartupProblem = null;
        webDownload = null;
        webDevelopmentProgress = null;
        webLoadingStage = WebDownloadProgress.LOADING_MESSAGE;
        failure = null;
        showSetup();
        render();
        startWebStartupTimeout();
        webView.reload();
    }

    private void startNetwork() {
        startNetwork(null);
    }
    private void startNetwork(String authKey) {
        if (busy || node != null || !visible) return;
        busy = true; failure = null; networkState.setText("Tailscale：正在连接"); render();
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
                    if (revision != generation || !visible || hasWebFailure()) { closeClient(client); return; }
                    networkDirectory = directory; node = client; busy = false; refreshNetwork();
                });
            } catch (Exception e) { main.post(() -> { if (revision == generation) {
                enrolling = null; busy = false; enabled = false; networkState.setText("Tailscale：未启动");
                fail(revision, "无法启动 Tailscale，请重试。", FailureKind.CONNECTION);
            } }); }
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
                    if (revision != generation || hasWebFailure()) return;
                    online = "Running".equals(state); loginURL = safeLogin(auth);
                    networkState.setText("Tailscale：" + (online ? "已连接" : "NeedsMachineAuth".equals(state) ? "等待网络管理员批准" : loginURL != null ? "等待网络登录" : "正在连接"));
                    if (online) connectionRoute = "内嵌 Tailscale";
                    if (restoring && online) { busy = false; verify(); return; }
                    if (restoring && loginURL != null) {
                        fail(revision, "Tailscale 入网授权需更新，请在电脑生成包含 Key 的配对码，再扫码更新连接。", FailureKind.CONNECTION);
                        return;
                    }
                    if (enrolling != null) {
                        if (online) {
                            Invitation link = enrolling; enrolling = null;
                            Runnable resume = enrollmentAction; enrollmentAction = null;
                            getPreferences(MODE_PRIVATE).edit().putString("networkState", new java.io.File(networkDirectory).getName()).apply();
                            busy = false;
                            if (resume != null) resume.run(); else claim(link);
                            return;
                        }
                        if (SystemClock.elapsedRealtime() >= enrollmentDeadline || System.currentTimeMillis() >= enrolling.expiresAt || loginURL != null || "NeedsMachineAuth".equals(state)) {
                            stopNetwork(true); showFailure(rememberedComputer ? FailureKind.CONNECTION : FailureKind.PAIRING,
                                "入网未完成，请检查 Key 是否已使用、过期或需要管理员批准，再重新生成邀请。"); return;
                        }
                        busy = true;
                    }
                    render();
                    if (!online && loginURL == null) main.postDelayed(networkPoll, 1500);
                });
            } catch (Exception e) { main.post(() -> { if (revision == generation) fail(revision, "网络状态读取失败，请重新连接"); }); }
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
        enrolling = null; enrollmentAction = null; invitation.setText("");
        main.removeCallbacks(networkPoll); main.removeCallbacks(approvalPoll); main.removeCallbacks(reconnectPoll);
        Client previous = node; node = null; online = false; loginURL = null; busy = false;
        clearComputer(); networkState.setText(enabled ? "Tailscale：已暂停" : "Tailscale：未启动"); render();
        if (previous != null) closeClient(previous);
    }
    private void closeClient(Client client) {
        try { closing = closer.submit(client::close); }
        catch (java.util.concurrent.RejectedExecutionException stopped) { Thread cleanup = new Thread(client::close, "weq-network-close"); cleanup.setDaemon(true); cleanup.start(); }
    }
    private void clearComputer() {
        healthEpoch++; connectionRecovery = 0;
        main.removeCallbacks(eventCheck); eventCheckPending = false; lastEventCheck = -5000;
        health = new ConnectionHealth(); connectionRoute = "未选择";
        closeWeb();
        generation++;
        main.removeCallbacks(approvalPoll); endpoint = null; token = null; fingerprint = null; connectionRoutes = null; claimID = null; paired = false; restoring = false; updatingConnection = false;
        computerVerified = false; failure = null; busy = false;
    }
    private void pair() {
        if (busy) return;
        try {
            Invitation link = Invitation.parse(invitation.getText().toString());
            reconnectPaused = false;
            if (rememberedComputer) { updateConnection(link); return; }
            if (link.multiRoute) {
                if (link.authKey != null && testControl != null) throw new Exception("测试网络不接受正式入网密钥");
                startMulti(new org.json.JSONArray(link.endpoints).toString(), link.fingerprint, link.authKey, "", () -> claim(link)); return;
            }
            if (link.fingerprint != null) { startDirect(link.endpoint, link.fingerprint, () -> claim(link)); return; }
            if (link.authKey != null) {
                if (testControl != null) throw new Exception("测试网络不接受正式入网密钥");
                        if (!visible || link.expiresAt <= System.currentTimeMillis()) { invitation.setText(""); showFailure(FailureKind.PAIRING, "邀请已过期，请重新生成。"); return; }
                        stopNetwork(true); enabled = true; enrolling = link; enrollmentDeadline = SystemClock.elapsedRealtime() + 45000;
                        startNetwork(link.authKey);
                return;
            }
            claim(link);
        } catch (Exception e) { showFailure(rememberedComputer ? FailureKind.VERIFICATION : FailureKind.PAIRING,
            "配对链接无效或已过期，请重新生成；旧版邀请需先连接网络。"); }
    }
    private void beginRoute() {
        if (webGateway == null || !restoring) { stopNetwork(true); return; }
        Client previous = node;
        node = null;
        if (previous != null) closeClient(previous);
        generation++;
    }

    private void startDirect(String address, String pin, Runnable next) {
        beginRoute(); busy = true; final int revision = generation; render();
        worker.execute(() -> {
            try {
                Client client = Androidnet.newDirectClient(address, pin);
                main.post(() -> {
                    if (revision != generation || hasWebFailure() || (!visible && webGateway == null)) { closeClient(client); return; }
                    node = client; fingerprint = pin; online = true; busy = false; connectionRoute = "系统网络（HTTPS）"; next.run();
                });
            } catch (Exception e) { fail(revision, "无法创建连接，请重试。", FailureKind.CONNECTION); }
        });
    }
    private void startMulti(String routes, String pin, String authKey, String token, Runnable next) {
        beginRoute(); busy = true; final int revision = generation; render();
        worker.execute(() -> {
            try {
                Future<?> pendingClose = closing;
                if (pendingClose != null) pendingClose.get();
                go.Seq.setContext(getApplicationContext());
                Androidnet.setInterfaces(interfaceSnapshot());
                String base = new java.io.File(getNoBackupFilesDir(), "tailnet").getAbsolutePath();
                String directory = authKey != null ? Androidnet.authStateDir(base, authKey) : networkDirectory != null ? networkDirectory : base;
                if (revision != generation || !visible) return;
                Client client = Androidnet.newPendingMultiClient(directory, routes, pin, authKey == null ? "" : authKey, token);
                main.post(() -> {
                    if (revision != generation || hasWebFailure() || (!visible && webGateway == null)) { closeClient(client); return; }
                    node = client;
                    worker.execute(() -> {
                        try {
                            client.connectRoutes();
                            boolean embedded = client.usesEmbeddedNetwork();
                            main.post(() -> {
                                if (revision != generation || hasWebFailure() || (!visible && webGateway == null)) return;
                                if (embedded) {
                                    networkDirectory = directory;
                                    if (authKey != null) getPreferences(MODE_PRIVATE).edit().putString("networkState", new java.io.File(directory).getName()).apply();
                                }
                                connectionRoute = embedded ? "内嵌 Tailscale" : "系统网络（HTTPS）";
                                networkState.setText(embedded ? "Tailscale：已连接" : "Tailscale：未使用（系统网络）");
                                fingerprint = pin; connectionRoutes = routes; online = true; busy = false; next.run();
                            });
                        } catch (Exception e) { failRoute(revision, e); }
                    });
                });
            } catch (Exception e) { failRoute(revision, e); }
        });
    }
    private void updateConnection(Invitation link) throws Exception {
        JSONObject saved = ConnectionStore.load(this);
        if (saved == null) throw new Exception("无法读取保存的电脑凭据");
        final String credential = saved.getString("token");
        if (!credential.matches("[a-f0-9]{64}")) throw new Exception("电脑凭据无效");
        Runnable resume = () -> {
            endpoint = link.endpoint; token = credential; paired = true; restoring = true;
            updatingConnection = true; verify();
        };
        Runnable connect = () -> {
            if (link.multiRoute) startMulti(new org.json.JSONArray(link.endpoints).toString(), link.fingerprint, null, credential, resume);
            else if (link.fingerprint != null) startDirect(link.endpoint, link.fingerprint, resume);
            else resume.run();
            updatingConnection = true;
        };
        if (link.authKey != null) {
            if (testControl != null) throw new Exception("测试网络不接受正式入网密钥");
            // 显式更新 Key 时先完成入网，不因局域网先响应而丢掉新 Key。
            stopNetwork(true); enabled = true;
            enrolling = link; enrollmentAction = connect; enrollmentDeadline = SystemClock.elapsedRealtime() + 45000;
            startNetwork(link.authKey);
        } else if (link.multiRoute || link.fingerprint != null) connect.run();
        else {
            stopNetwork(true); enabled = true;
            endpoint = link.endpoint; token = credential; paired = true; restoring = true;
            startNetwork();
        }
        updatingConnection = true;
    }
    private void failRoute(int revision, Exception e) {
        // 选路探测已包含鉴权状态读取，撤销授权要在建连阶段直接清凭据，而不是当成普通网络失败。
        String message = e.getMessage();
        if (message != null && message.contains("设备未授权")) fail(revision, AUTHORIZATION_REJECTED);
        else if (message != null && message.contains("certificate changed"))
            fail(revision, "电脑证书已变化。请核对电脑后扫码更新连接。", FailureKind.VERIFICATION);
        else fail(revision, "请确认电脑上的 WeQ 正在运行，且手机能访问电脑。", FailureKind.CONNECTION);
    }
    private boolean restoreComputer() {
        if (reconnectPaused || busy || testControl != null || invitation.length() > 0) return false;
        try {
            JSONObject saved = ConnectionStore.load(this);
            if (saved == null) {
                openingSavedWeb = false;
                showSetup(); render();
                return false;
            }
            rememberedComputer = true;
            failure = null;
            computerVerified = false;
            String address = saved.getString("endpoint"), credential = saved.getString("token"), pin = saved.optString("fingerprint", "");
            if (!credential.matches("[a-f0-9]{64}")) throw new Exception("电脑凭据无效");
            String localSecret = Invitation.credential();
            boolean showCached = false;
            if (webGateway == null) {
                try {
                    WebGateway cached = Androidnet.newWebGateway(credential, localSecret);
                    if (cached.hasRelease()) { webGateway = cached; showCached = true; }
                    else cached.close();
                } catch (Exception unavailable) { /* 普通连接仍可继续。 */ }
            }
            openingSavedWeb = false;
            if (!showCached && webGateway == null) { showSetup(); renderConnectionMenu(); }
            restoring = true;
            Runnable resume = () -> { endpoint = address; token = credential; paired = true; restoring = true; computerState.setText("正在连接电脑"); verify(); };
            org.json.JSONArray routes = saved.optJSONArray("endpoints");
            if (routes != null) {
                if (routes.length() == 0 || !address.equals(routes.getString(0))) throw new Exception("电脑地址无效");
                startMulti(routes.toString(), pin, null, credential, resume);
            }
            else if (!pin.isEmpty()) startDirect(address, pin, resume);
            else { endpoint = address; token = credential; paired = true; restoring = true; enabled = true; startNetwork(); }
            if (showCached) showWeb(webGateway.origin(), localSecret, generation, false);
            return true;
        } catch (Exception e) {
            if (webView == null) closeWeb();
            showFailure(FailureKind.VERIFICATION, "无法读取已保存的电脑凭据。");
            return false;
        }
    }
    private void claim(Invitation link) {
        if (!online || node == null) { showFailure(FailureKind.PAIRING, "此邀请不含入网密钥，请先连接电脑所在的网络。"); return; }
        try {
            endpoint = link.endpoint; token = Invitation.credential();
            invitation.setText("");
            JSONObject body = new JSONObject().put("invitation", link.secret).put("name", "WeQ Remote Android").put("tokenHash", Invitation.hash(token)).put("scope", "web:access");
            busy = true; failure = null; render();
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
                        codeView.setText(code); render(); pollApproval();
                    });
                } catch (Exception e) { fail(revision, e.getMessage()); }
            });
        } catch (Exception e) { showFailure(FailureKind.PAIRING, "请重试配对。"); }
    }
    private void pollApproval() {
        if (claimID == null || node == null || paired) return;
        if (System.currentTimeMillis() >= expiresAt) { clearComputer(); showFailure(FailureKind.PAIRING, "配对确认已超时，请重新生成邀请。"); return; }
        final Client client = node; final int revision = generation; final String id = claimID, address = endpoint, credential = token;
        worker.execute(() -> {
            try {
                JSONObject approval = response(client.request(address, "/v1/pair/" + id, "GET", credential, ""));
                if (!id.equals(approval.getString("id")) || !"web:access".equals(approval.getString("scope"))) throw new Exception("电脑返回了不兼容的数据，请升级电脑端");
                main.post(() -> { if (revision != generation || !id.equals(claimID)) return; if (approval.optBoolean("approved")) {
                    try { if (!BuildConfig.TESTING || fingerprint != null) { ConnectionStore.save(this, endpoint, token, fingerprint, connectionRoutes); rememberedComputer = true; } claimID = null; paired = true; computerVerified = true; restoring = true; verify(); }
                    catch (Exception e) { fail(revision, "无法保存电脑凭据，请重试"); }
                } else main.postDelayed(approvalPoll, 1500); });
            } catch (Exception e) { fail(revision, e.getMessage()); }
        });
    }
    private void verify() {
        if (node == null || !paired || busy || !visible || hasWebFailure()) return;
        main.removeCallbacks(reconnectPoll);
        final Client client = node; final int revision = generation; final String address = endpoint, credential = token;
        final long timeout = health.requestTimeout();
        final boolean recoverRoutes = health.recovering();
        final boolean liveCheck = webLoaded;
        final WebGateway gateway = webGateway;
        final int epoch = healthEpoch;
        if (webLoaded) { health.beginCheck(SystemClock.elapsedRealtime()); scheduleConnectionWarning(); }
        busy = true; failure = null; render();
        worker.execute(() -> {
            FailureKind failureKind = FailureKind.CONNECTION;
            try {
                Androidnet.setInterfaces(interfaceSnapshot());
                long started = SystemClock.elapsedRealtime();
                String raw = liveCheck ? client.checkConnection(address, credential, timeout, recoverRoutes) : client.request(address, "/v1/status", "GET", credential, "");
                failureKind = FailureKind.VERIFICATION;
                JSONObject status = response(raw);
                long milliseconds = SystemClock.elapsedRealtime() - started;
                if (!"WeQ Remote".equals(status.getString("product")) || status.getInt("protocol") != 1 || !"status:read".equals(status.getString("scope")) || !status.getBoolean("online")) throw new Exception("电脑返回了不兼容的数据");
                String webRelease = status.optString("webRelease", "");
                if (gateway != null) {
                    client.attachWebRelease(gateway, address, webRelease);
                }
                boolean webReady = gateway != null;
                boolean embedded = client.usesEmbeddedNetwork();
                String tailnet = liveCheck ? (embedded ? "Running" : "Stopped") : tailnetState(client, embedded);
                main.post(() -> {
                    if (revision != generation || !credential.equals(token)) return;
                    if (liveCheck && epoch != healthEpoch) { busy = false; requestConnectionCheck(true); return; }
                    if (hasWebFailure()) return;
                    computerVerified = true;
                    if (updatingConnection) {
                        try { ConnectionStore.save(this, endpoint, credential, fingerprint, connectionRoutes); updatingConnection = false; }
                        catch (Exception e) { fail(revision, "无法保存新的电脑地址，请重试"); return; }
                    }
                    busy = false; render();
                    if (visible) {
                        connectionRoute = embedded ? "内嵌 Tailscale" : "系统网络（HTTPS）";
                        networkState.setText("Tailscale：" + ("Running".equals(tailnet) ? "已连接" : embedded ? "状态待确认" : "未使用（系统网络）"));
                        if (health.suspected) connectionRecovery++;
                        health.succeeded(System.currentTimeMillis(), milliseconds, SystemClock.elapsedRealtime());
                        publishConnectionHealth();
                        scheduleConnectionWarning();
                        render();
                        main.removeCallbacks(reconnectPoll);
                        main.postDelayed(reconnectPoll, 15000);
                    }
                    boolean open = WebStartup.shouldOpenWeb(restoring, webView != null, webReady);
                    restoring = false;
                    if (open && visible && webGateway == null) openWeb(webRelease);
                });
            } catch (Exception e) {
                final FailureKind kind = failureKind;
                main.post(() -> {
                    if (revision != generation) return;
                    if (liveCheck && epoch != healthEpoch) { busy = false; requestConnectionCheck(true); return; }
                    computerVerified = false;
                    fail(revision, e.getMessage(), kind);
                });
            }
        });
    }
    private void openWeb(String webRelease) {
        final Client client = node; final int revision = generation;
        final String address = endpoint, credential = token, localSecret = Invitation.credential();
        busy = true; webLoadingStage = "正在准备网页连接"; render();
        worker.execute(() -> {
            WebGateway candidate = null;
            try {
                candidate = Androidnet.newWebGateway(credential, localSecret);
                client.attachWebRelease(candidate, address, webRelease);
                final WebGateway gateway = candidate;
                main.post(() -> {
                    if (revision != generation || !visible) { gateway.close(); return; }
                    webGateway = gateway;
                    busy = false;
                    showWeb(gateway.origin(), localSecret, revision, true);
                });
            } catch (Exception e) {
                if (candidate != null) candidate.close();
                failWebGateway(revision);
            }
        });
    }

    private void showWeb(String origin, String localSecret, int revision, boolean showProgress) {
        webLoaded = false;
        webMenuReady = false;
        webStartupProblem = null;
        renderConnectionMenu();
        startWebStartupTimeout();
        android.webkit.CookieManager cookies = android.webkit.CookieManager.getInstance();
        cookies.removeAllCookies(ignored -> {
            if (revision != generation || !visible || webGateway == null || hasWebFailure()) return;
            cookies.setCookie(origin, "weq_remote_local=" + localSecret + "; HttpOnly; SameSite=Strict; Path=/", accepted -> {
                if (revision != generation || !visible || webGateway == null || hasWebFailure()) return;
                if (!accepted) { finishWebFailure(FailureKind.WEB_LOAD, webRecovery()); return; }
                disposeWebPage(false);
                webView = new android.webkit.WebView(this);
                final android.webkit.WebView page = webView;
                android.webkit.WebSettings settings = webView.getSettings();
                settings.setJavaScriptEnabled(true); settings.setDomStorageEnabled(true);
                settings.setUserAgentString(settings.getUserAgentString() + " WeQRemote");
                settings.setAllowFileAccess(false); settings.setAllowContentAccess(false);
                settings.setMixedContentMode(android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW);
                cookies.setAcceptThirdPartyCookies(webView, false);
                webFeatures = new WebFeatures(this, webView, origin, webGateway);
                webView.setWebViewClient(new android.webkit.WebViewClient() {
                    private boolean allowed(Uri url) { return "http".equals(url.getScheme()) && "127.0.0.1".equals(url.getHost()) && url.getPort() == Uri.parse(origin).getPort(); }
                    @Override public void onPageStarted(android.webkit.WebView view, String url, android.graphics.Bitmap icon) {
                        if (webView != page) return;
                        webStartupRevision++;
                        webLoaded = false;
                        webMenuReady = false;
                        webStartupProblem = null;
                        webDownload = null; webDevelopmentProgress = null;
                        webLoadingStage = WebDownloadProgress.LOADING_MESSAGE;
                        render();
                        startWebStartupTimeout();
                    }
                    @Override public void onPageCommitVisible(android.webkit.WebView view, String url) {
                        // 不等待图片等尾部资源完成，尽早订阅并补读网页已经发出的启动状态。
                        if (webView == page && allowed(Uri.parse(url)) && webFeatures != null) {
                            webFeatures.observeMenu(webStartupRevision);
                            webFeatures.observeStartup();
                        }
                    }
                    @Override public void onPageFinished(android.webkit.WebView view, String url) {
                        if (view != page || webView != page || !allowed(Uri.parse(url))) return;
                        if (webFeatures != null) webFeatures.pageReady();
                    }
                    @Override public void onReceivedError(android.webkit.WebView view, android.webkit.WebResourceRequest request, android.webkit.WebResourceError error) {
                        if (webView == page && request.isForMainFrame() && !webLoaded) failWebLoad(FailureKind.WEB_LOAD, webRecovery());
                        else if (webView == page && allowed(request.getUrl()) && !webLoaded) recordWebResourceFailure(page, request.getUrl().getPath(), 0);
                    }
                    @Override public void onReceivedHttpError(android.webkit.WebView view, android.webkit.WebResourceRequest request, android.webkit.WebResourceResponse response) {
                        if (webView == page && request.isForMainFrame() && !webLoaded && response.getStatusCode() >= 400)
                            failWebLoad(FailureKind.WEB_LOAD, webRecovery());
                        else if (webView == page && allowed(request.getUrl()) && !webLoaded && response.getStatusCode() >= 400)
                            recordWebResourceFailure(page, request.getUrl().getPath(), response.getStatusCode());
                    }
                    @Override public boolean onRenderProcessGone(android.webkit.WebView view, android.webkit.RenderProcessGoneDetail detail) {
                        if (webView == page) {
                            disposeWebPage(true);
                            android.webkit.CookieManager.getInstance().removeAllCookies(null);
                            finishWebFailure(FailureKind.WEB_LOAD, webRecovery());
                        }
                        return true;
                    }
                    @Override public boolean shouldOverrideUrlLoading(android.webkit.WebView view, android.webkit.WebResourceRequest request) { return request.isForMainFrame() ? webFeatures == null || webFeatures.navigate(request.getUrl()) : !allowed(request.getUrl()); }
                    @Override public android.webkit.WebResourceResponse shouldInterceptRequest(android.webkit.WebView view, android.webkit.WebResourceRequest request) {
                        if (allowed(request.getUrl())) return null;
                        return new android.webkit.WebResourceResponse("text/plain", "UTF-8", 403, "Forbidden", java.util.Collections.emptyMap(), new java.io.ByteArrayInputStream(new byte[0]));
                    }
                });
                // 缓存启动只显示网页和临时菜单，不挂载整张连接页。
                LinearLayout shell = new LinearLayout(this); shell.setOrientation(LinearLayout.VERTICAL); shell.setBackgroundColor(webBackgroundColor());
                shell.addView(webView, new LinearLayout.LayoutParams(-1, 0, 1f));
                if (insetWebView) applyWebInsets(shell);
                webShell = shell;
                surface.addView(shell, 0, new android.widget.FrameLayout.LayoutParams(-1, -1));
                if (showProgress) showSetup();
                else surface.removeView(setupView);
                render();
                webView.loadUrl(origin + "/");
            });
        });
    }

    private void startWebStartupTimeout() {
        main.removeCallbacks(webStartupTimeout);
        main.postDelayed(webStartupTimeout, 45000);
    }

    void receiveWebMenuReady(android.webkit.WebView page, int revision, boolean ready) {
        if (webView != page || webStartupRevision != revision || webMenuReady == ready) return;
        webMenuReady = ready;
        renderConnectionMenu();
    }
    private String tailnetState(Client client, boolean embedded) {
        if (!embedded) return "Stopped";
        try { return new JSONObject(client.status()).optString("state"); }
        catch (Exception unavailable) { return "Unknown"; }
    }
    void receiveWebStartup(android.webkit.WebView page, String state, String message) {
        if (webView != page || webLoaded) return;
        if ("loading".equals(state)) {
            if (message == null || message.isEmpty()) return;
            webLoadingStage = message.substring(0, Math.min(message.length(), 100));
            renderSetupProgress();
        } else if ("ready".equals(state) || "action-required".equals(state)) showWebPage();
        else if ("error".equals(state)) {
            // 旧网页用文案区分资源与渲染异常；有具体诊断的其他消息仍原样显示。
            if ("WeQ 界面资源加载失败，自动重试一次后仍未成功，请检查电脑与网络后重试。".equals(message)) {
                failWebLoad(FailureKind.WEB_LOAD, "网页资源自动重试后仍未加载完成。");
            } else {
                boolean hasDetail = message != null && !message.isEmpty() && !"WeQ 界面启动异常，请重新连接。".equals(message);
                failWebLoad(FailureKind.WEB_STARTUP, hasDetail ? message.substring(0, Math.min(message.length(), 500)) : webRecovery());
            }
        }
    }
    void receiveWebDownload(android.webkit.WebView page, WebDownloadProgress value) {
        if (webView != page || webLoaded) return;
        webDownload = value;
        renderSetupProgress();
    }
    void receiveWebDevelopmentProgress(android.webkit.WebView page, WebDownloadProgress.Development value) {
        if (webView != page || webLoaded || (webDevelopmentProgress != null && value.completed <= webDevelopmentProgress.completed)) return;
        webDevelopmentProgress = value;
        renderSetupProgress();
    }
    void recordWebConsoleFailure(android.webkit.WebView page, String message) {
        if (webView != page || webLoaded) return;
        String problem = WebStartup.consoleProblem(message);
        if (problem != null) webStartupProblem = problem;
    }
    private void recordWebResourceFailure(android.webkit.WebView page, String path, int status) {
        if (webView != page || webLoaded) return;
        String problem = WebStartup.resourceProblem(path, status);
        if (problem == null) return;
        final int revision = webStartupRevision;
        // 新电脑网页负责一次资源重试及最终错误；旧网页仍沿用原生失败提示。
        page.evaluateJavascript("window.weqRemoteStartupRecovery === true", managed -> {
            if (webView != page || webLoaded || webStartupRevision != revision) return;
            if (!"true".equals(managed)) failWebLoad(FailureKind.WEB_LOAD, problem);
        });
    }
    private void showWebPage() {
        if (webLoaded) return;
        main.removeCallbacks(webStartupTimeout);
        webLoaded = true;
        webDevelopmentProgress = null;
        health.resume(SystemClock.elapsedRealtime());
        publishConnectionHealth();
        scheduleConnectionWarning();
        main.removeCallbacks(reconnectPoll);
        if (visible) main.post(reconnectPoll);
        surface.removeView(setupView);
        render();
    }
    private String webRecovery() {
        return computerVerified ? "本次已连到电脑，无需重新扫码。" : "可使用已保存的配对重试，无需重新扫码。";
    }

    private void failWebGateway(int revision) {
        main.post(() -> {
            if (revision != generation || hasWebFailure()) return;
            if (webLoaded) { fail(revision, "无法准备网页连接。"); return; }
            computerVerified = true;
            finishWebFailure(FailureKind.WEB_LOAD, webRecovery());
        });
    }

    private void failWebLoad(FailureKind kind, String detail) {
        final android.webkit.WebView failedPage = webView;
        final int revision = webStartupRevision;
        main.post(() -> {
            if (webView == null || webView != failedPage || webLoaded || webStartupRevision != revision) return;
            finishWebFailure(kind, detail);
        });
    }

    private void finishWebFailure(FailureKind kind, String detail) {
        reconnectPaused = true;
        enabled = false;
        main.removeCallbacks(reconnectPoll);
        main.removeCallbacks(networkPoll);
        busy = false; paired = false; restoring = false; webLoaded = false;
        failure = new HomeFailure(kind, detail);
        closeWeb();
        render();
    }
    private int webBackgroundColor() {
        boolean dark = (getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES;
        return dark ? Color.rgb(18, 20, 22) : Color.rgb(245, 247, 247);
    }
    // Chromium 136 起全屏 WebView 可以把系统栏安全区透传给网页的 env(safe-area-inset-*).
    private boolean webViewHandlesSafeArea() {
        try {
            android.content.pm.PackageInfo info = android.webkit.WebView.getCurrentWebViewPackage();
            if (info == null || info.versionName == null) return false;
            return Integer.parseInt(info.versionName.split("\\.")[0]) >= 136;
        } catch (Exception e) { return false; }
    }
    private void applyWebInsets(LinearLayout shell) {
        shell.setOnApplyWindowInsetsListener((view, insets) -> {
            android.graphics.Rect bars = WindowInsetsHelper.webInsets(insets);
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom);
            return insets;
        });
        shell.requestApplyInsets();
    }
    private void closeWeb() {
        main.removeCallbacks(healthDeadline);
        main.removeCallbacks(webStartupTimeout);
        webLoaded = false;
        webMenuReady = false;
        openingSavedWeb = false;
        webDownload = null;
        webDevelopmentProgress = null;
        if (webView != null) {
            disposeWebPage(false);
            android.webkit.CookieManager.getInstance().removeAllCookies(null);
        }
        WebGateway gateway = webGateway;
        webGateway = null;
        if (gateway != null) gateway.close();
        showSetup();
        render();
    }

    private void disposeWebPage(boolean rendererGone) {
        if (webFeatures != null) { webFeatures.close(rendererGone); webFeatures = null; }
        if (webView != null) {
            android.webkit.WebView page = webView;
            webView = null;
            if (page.getParent() instanceof android.view.ViewGroup) ((android.view.ViewGroup) page.getParent()).removeView(page);
            if (!rendererGone) page.stopLoading();
            page.destroy();
        }
        if (webShell != null) { surface.removeView(webShell); webShell = null; }
    }
    @Override public void onBackPressed() {
        if (webFeatures != null && webFeatures.exitFullscreen()) return;
        if (webView != null) {
            final android.webkit.WebView page = webView;
            page.evaluateJavascript("Boolean(window.weqMobileNavigation && window.weqMobileNavigation.back())", result -> {
                if (webView == page && !"true".equals(result)) MainActivity.super.onBackPressed();
            });
        }
        else super.onBackPressed();
    }
    private JSONObject response(String raw) throws Exception {
        JSONObject envelope = new JSONObject(raw); int status = envelope.getInt("status");
        if (status == 401) throw new Exception(AUTHORIZATION_REJECTED);
        if (status < 200 || status >= 300) throw new Exception("电脑返回 HTTP " + status + "。");
        return new JSONObject(envelope.getString("body"));
    }
    private void fail(int revision, String message) { fail(revision, message, FailureKind.VERIFICATION); }

    private void fail(int revision, String message, FailureKind kind) { main.post(() -> {
        if (revision != generation) return;
        boolean rejected = AUTHORIZATION_REJECTED.equals(message);
        boolean updateFailed = updatingConnection;
        boolean wasPaired = rememberedComputer || (paired && claimID == null);
        boolean revoked = rejected && wasPaired && !updateFailed;
        if (!revoked && hasWebFailure()) return;
        if (!rejected && webGateway != null) {
            busy = false;
            if (restoring && !paired && node != null) {
                Client previous = node;
                node = null;
                closeClient(previous);
            }
            if (visible && webLoaded) { health.checkFailed(SystemClock.elapsedRealtime()); scheduleConnectionWarning(); render(); }
            main.removeCallbacks(reconnectPoll);
            if (visible) main.postDelayed(reconnectPoll, webLoaded ? health.checkInterval() : 5000);
            return;
        }
        if (revoked) { closeWeb(); ConnectionStore.delete(this); rememberedComputer = false; Androidnet.clearWebCache(); }
        stopNetwork(true);
        if (revoked) showFailure(FailureKind.AUTHORIZATION, AUTHORIZATION_REJECTED);
        else if (rejected && updateFailed) showFailure(FailureKind.VERIFICATION, "新入口未接受现有授权，原连接已保留。");
        else showFailure(wasPaired ? kind : FailureKind.PAIRING, rejected ? "电脑未接受本次配对，请生成新的配对码。" : message == null ? "请重试。" : message);
        if (updateFailed) { reconnectPaused = true; return; }
        if (!BuildConfig.TESTING && visible) main.postDelayed(reconnectPoll, 5000);
    }); }
    @Override protected void onActivityResult(int request, int result, Intent data) { super.onActivityResult(request, result, data); if (webFeatures != null && webFeatures.result(request, result, data)) return; if (request == 7 && result == RESULT_OK && data != null) { invitation.setText(data.getStringExtra("invitation")); main.post(this::pair); } }
    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(request, permissions, results);
        if (request == WebFeatures.MEDIA && webFeatures != null) webFeatures.grantMedia();
    }
}
