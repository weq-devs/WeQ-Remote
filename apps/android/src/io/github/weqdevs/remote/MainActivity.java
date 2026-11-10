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
    private boolean updatingConnection;
    private Runnable enrollmentAction;
    private boolean rememberedComputer;
    private long expiresAt;
    private String testControl;
    private String networkDirectory;
    private Invitation enrolling;
    private long enrollmentDeadline;
    private View setupView;
    android.webkit.WebView webView;
    private WebFeatures webFeatures;
    TextView networkState, computerState, detail, error, codeView, statusPill;
    private String appVersion = "";
    EditText invitation;
    Button pairButton, verifyButton, retryButton;
    android.widget.ImageButton disconnectButton, updateButton;
    private LinearLayout connectionActions;
    android.view.View scanButton;
    private LinearLayout pairSection;
    private android.widget.ProgressBar progress;
    private DownloadRing downloadRing;
    private WebDownloadProgress webDownload;
    private boolean webStartupReported;
    private android.widget.ImageView markIcon;
    private android.view.View statusDot;
    private int accentColor, idleDotColor;
    private boolean webLoaded;
    private String webLoadingStage = "正在准备网页连接";
    private String webStartupProblem;
    private final Runnable webStartupTimeout = () -> {
        if (webView != null && !webLoaded) failWebLoad(webStartupProblem != null ? webStartupProblem : "WeQ 页面准备超时（" + webLoadingStage + "），请重试并确认电脑已更新到支持页面就绪通知的版本。");
    };
    private boolean reconnectPaused;
    private final Runnable networkPoll = new Runnable() { public void run() { refreshNetwork(); } };
    private final Runnable approvalPoll = new Runnable() { public void run() { pollApproval(); } };
    private final Runnable reconnectPoll = () -> {
        if (!visible || busy || reconnectPaused) return;
        if (webView != null) verify();
        else if (claimID == null) restoreComputer();
    };

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        go.Seq.setContext(getApplicationContext());
        try { Androidnet.setWebCacheDirectory(new java.io.File(getCacheDir(), "web-code").getAbsolutePath()); }
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
        setContentView(page);

        LinearLayout topBar = new LinearLayout(this);
        topBar.setOrientation(LinearLayout.HORIZONTAL);
        topBar.setGravity(android.view.Gravity.CENTER_VERTICAL);
        android.widget.ImageView brandMark = new android.widget.ImageView(this);
        brandMark.setImageResource(getResources().getIdentifier("ic_computer", "drawable", getPackageName()));
        brandMark.setColorFilter(accent);
        brandMark.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        topBar.addView(brandMark, new LinearLayout.LayoutParams(dp(24), dp(24)));
        TextView brand = text("WeQ Remote", 16);
        brand.setTypeface(null, android.graphics.Typeface.BOLD);
        brand.setTextColor(ink);
        brand.setPadding(dp(10), 0, 0, 0);
        topBar.addView(brand);
        topBar.addView(new android.view.View(this), new LinearLayout.LayoutParams(0, 1, 1f));
        LinearLayout statusChip = new LinearLayout(this);
        statusChip.setOrientation(LinearLayout.HORIZONTAL);
        statusChip.setGravity(android.view.Gravity.CENTER_VERTICAL);
        statusChip.setPadding(dp(12), dp(6), dp(12), dp(6));
        statusChip.setBackground(background(card, border, dp(100)));
        statusDot = new android.view.View(this);
        statusDot.setBackground(oval(muted));
        statusChip.addView(statusDot, new LinearLayout.LayoutParams(dp(6), dp(6)));
        statusPill = text("未连接", 12);
        statusPill.setTextColor(muted);
        statusPill.setPadding(dp(6), 0, 0, 0);
        statusChip.addView(statusPill);
        topBar.addView(statusChip);
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
        computerState = text("连接电脑", 26);
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
        TextView scanLabel = text("扫码连接", 17);
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
            else { reconnectPaused = false; restoreComputer(); }
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

        networkState = text("网络：未启动", 11);
        networkState.setTextColor(muted);
        networkState.setGravity(android.view.Gravity.CENTER);
        LinearLayout.LayoutParams networkParams = new LinearLayout.LayoutParams(-1, -2);
        networkParams.topMargin = dp(8);
        dock.addView(networkState, networkParams);
        try { appVersion = getPackageManager().getPackageInfo(getPackageName(), 0).versionName; } catch (Exception ignored) { }
        TextView version = text(appVersion == null || appVersion.isEmpty() ? "WeQ Remote" : "WeQ Remote " + appVersion, 11);
        version.setTextColor(muted);
        version.setGravity(android.view.Gravity.CENTER);
        LinearLayout.LayoutParams versionParams = new LinearLayout.LayoutParams(-1, -2);
        versionParams.topMargin = dp(2);
        dock.addView(version, versionParams);
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

    private void render() {
        boolean loading = busy || claimID != null || (paired && !webLoaded);
        boolean canPair = claimID == null && !rememberedComputer && !paired;
        pairSection.setVisibility(canPair ? View.VISIBLE : View.GONE);
        scanButton.setEnabled(!busy);
        pairButton.setEnabled(!busy && claimID == null && invitation.length() > 0);
        pairButton.setVisibility(invitation.length() > 0 ? View.VISIBLE : View.GONE);
        verifyButton.setVisibility(paired && BuildConfig.TESTING ? View.VISIBLE : View.GONE);
        verifyButton.setEnabled(!busy);
        boolean measured = loading && webView != null && !webLoaded && webDownload != null && webDownload.downloading();
        downloadRing.update(measured ? webDownload : null);
        progress.setVisibility(loading && !measured ? View.VISIBLE : View.GONE);
        markIcon.setVisibility(loading ? View.INVISIBLE : View.VISIBLE);
        connectionActions.setVisibility(paired || rememberedComputer || loading ? View.VISIBLE : View.GONE);
        updateButton.setVisibility(rememberedComputer ? View.VISIBLE : View.GONE);
        retryButton.setVisibility(rememberedComputer || loading ? View.VISIBLE : View.GONE);
        retryButton.setText(isConnecting() ? "停止" : "连接");
        retryButton.setEnabled(true);
        disconnectButton.setVisibility(paired || claimID != null || rememberedComputer ? View.VISIBLE : View.GONE);
        codeView.setVisibility(claimID != null ? View.VISIBLE : View.GONE);
        statusPill.setText(statusText());
        statusDot.setBackground(oval(statusText().equals("未连接") ? idleDotColor : accentColor));
        computerState.setText(heroTitle());
        detail.setText(heroDetail());
        detail.setVisibility(detail.length() > 0 ? View.VISIBLE : View.GONE);
    }

    private boolean isConnecting() { return busy || claimID != null || (paired && !webLoaded); }

    private void scanConnection() {
        reconnectPaused = true;
        stopNetwork(true);
        startActivityForResult(new Intent(this, ScannerActivity.class), 7);
    }

    private String heroTitle() {
        if (claimID != null) return "等待电脑确认";
        if (!webLoaded && webDownload != null && webDownload.downloading()) return "正在下载网页资源";
        if (!webLoaded && (paired || webView != null)) return webLoadingStage;
        if (busy) return paired ? "正在验证电脑授权" : "正在连接电脑";
        if (error.length() > 0) return "连接未通过";
        if (rememberedComputer) return "我的电脑";
        return "连接电脑";
    }

    private String heroDetail() {
        if (claimID != null) return "在电脑上核对校验码，并允许这台手机访问";
        if (!webLoaded && (paired || webView != null)) return webDownload != null ? webDownload.detail() : endpoint != null ? "地址  " + endpoint : "页面准备好后自动进入";
        if (busy) return endpoint != null ? "地址  " + endpoint : "正在准备与电脑的连接";
        if (error.length() > 0) return rememberedComputer ? (endpoint != null ? "地址  " + endpoint : "电脑暂时不可用") : "请确认电脑在线后重试";
        if (rememberedComputer) return endpoint != null ? "地址  " + endpoint : "打开后会自动连接上次的电脑";
        return "在电脑上的 WeQ 生成配对码，扫码或粘贴链接即可连接";
    }

    private String statusText() {
        if (claimID != null) return "等待批准";
        if (busy || (paired && !webLoaded)) return paired ? "正在进入" : "连接中";
        if (paired) return "已连接";
        return "未连接";
    }

    private void forgetComputer() {
        new android.app.AlertDialog.Builder(this).setTitle("删除电脑？")
            .setMessage("将清除本机保存的电脑连接，下次需要重新扫码并在电脑上批准。电脑上的设备授权不会撤销。")
            .setNegativeButton("取消", null)
            .setPositiveButton("删除电脑", (dialog, which) -> {
                reconnectPaused = true;
                ConnectionStore.delete(this); rememberedComputer = false; Androidnet.clearWebCache(); stopNetwork(true);
            }).show();
    }

    void showConnectionMenu() {
        if (webView == null || !webLoaded || isFinishing()) return;
        new android.app.AlertDialog.Builder(this)
            .setItems(new String[]{"重新加载", "断开连接"}, (dialog, which) -> {
                if (which == 0) reloadWeb();
                else {
                    reconnectPaused = true;
                    stopNetwork(true);
                    if (android.animation.ValueAnimator.areAnimatorsEnabled()) {
                        setupView.setAlpha(0);
                        setupView.animate().alpha(1).setDuration(180).start();
                    }
                }
            }).setNegativeButton("取消", null).show();
    }

    private void reloadWeb() {
        if (webView == null) return;
        webLoaded = false;
        webStartupProblem = null;
        webLoadingStage = "正在下载网页资源";
        error.setText("");
        android.view.ViewGroup root = (android.view.ViewGroup) webView.getParent().getParent();
        if (setupView.getParent() == null) root.addView(setupView, new android.view.ViewGroup.LayoutParams(-1, -1));
        setupView.setAlpha(1); render(); webView.reload();
    }

    private void startNetwork() {
        startNetwork(null);
    }
    private void startNetwork(String authKey) {
        if (busy || node != null || !visible) return;
        busy = true; error.setText(""); networkState.setText("网络：正在连接"); render();
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
            } catch (Exception e) { main.post(() -> { if (revision == generation) { enrolling = null; busy = false; enabled = false; error.setText("网络启动失败，请重新生成一次性 Key 后重试"); networkState.setText("网络：未启动"); render(); } }); }
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
                    networkState.setText("网络：" + (online ? "已连接" : "NeedsMachineAuth".equals(state) ? "等待网络管理员批准" : loginURL != null ? "等待网络登录" : "正在连接"));
                    if (restoring && online) { busy = false; verify(); return; }
                    if (restoring && loginURL != null) { stopNetwork(true); error.setText("网络授权需更新，请在电脑重新生成配对码"); return; }
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
        enrolling = null; enrollmentAction = null; invitation.setText("");
        main.removeCallbacks(networkPoll); main.removeCallbacks(approvalPoll); main.removeCallbacks(reconnectPoll);
        Client previous = node; node = null; online = false; loginURL = null; busy = false;
        clearComputer(); networkState.setText(enabled ? "网络：已暂停" : "网络：未启动"); render();
        if (previous != null) closeClient(previous);
    }
    private void closeClient(Client client) {
        try { closing = closer.submit(client::close); }
        catch (java.util.concurrent.RejectedExecutionException stopped) { Thread cleanup = new Thread(client::close, "weq-network-close"); cleanup.setDaemon(true); cleanup.start(); }
    }
    private void clearComputer() {
        closeWeb();
        generation++;
        main.removeCallbacks(approvalPoll); endpoint = null; token = null; fingerprint = null; connectionRoutes = null; claimID = null; paired = false; restoring = false; updatingConnection = false;
        computerState.setText("未配对"); detail.setText(""); error.setText(""); busy = false;
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
                        if (!visible || link.expiresAt <= System.currentTimeMillis()) { invitation.setText(""); error.setText("邀请已过期，请重新生成"); return; }
                        stopNetwork(true); enabled = true; enrolling = link; enrollmentDeadline = SystemClock.elapsedRealtime() + 45000;
                        startNetwork(link.authKey);
                return;
            }
            claim(link);
        } catch (Exception e) { error.setText("配对链接无效或已过期，请重新生成；旧版邀请需先连接网络"); render(); }
    }
    private void startDirect(String address, String pin, Runnable next) {
        stopNetwork(true); busy = true; networkState.setText("网络：正在连接系统网络"); final int revision = generation; render();
        worker.execute(() -> {
            try {
                Client client = Androidnet.newDirectClient(address, pin);
                main.post(() -> {
                    if (revision != generation || !visible) { closeClient(client); return; }
                    node = client; fingerprint = pin; online = true; busy = false; networkState.setText("网络：已连接（系统网络）"); next.run();
                });
            } catch (Exception e) { fail(revision, "无法创建连接，请重新扫描二维码"); }
        });
    }
    private void startMulti(String routes, String pin, String authKey, String token, Runnable next) {
        stopNetwork(true); busy = true; networkState.setText("网络：正在探测连接入口"); final int revision = generation; render();
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
                    if (revision != generation || !visible) { closeClient(client); return; }
                    node = client;
                    worker.execute(() -> {
                        try {
                            client.connectRoutes();
                            boolean embedded = client.usesEmbeddedNetwork();
                            main.post(() -> {
                                if (revision != generation || !visible) return;
                                if (embedded) {
                                    networkDirectory = directory;
                                    if (authKey != null) getPreferences(MODE_PRIVATE).edit().putString("networkState", new java.io.File(directory).getName()).apply();
                                }
                                networkState.setText(embedded ? "网络：已连接（内嵌 Tailscale）" : "网络：已连接（系统网络）");
                                fingerprint = pin; connectionRoutes = routes; online = true; busy = false; next.run();
                            });
                        } catch (Exception e) { fail(revision, routeFailureMessage(e)); }
                    });
                });
            } catch (Exception e) { fail(revision, routeFailureMessage(e)); }
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
    private String routeFailureMessage(Exception e) {
        // 选路探测已包含鉴权状态读取，撤销授权要在建连阶段直接清凭据，而不是当成普通网络失败。
        String message = e.getMessage();
        if (message != null && message.contains("设备未授权")) return "设备未授权或授权已被撤销，请重新配对";
        if (message != null && message.contains("certificate changed")) return "电脑证书已变化，请删除电脑后重新配对";
        return "无法连接电脑，请检查局域网、Tailscale 服务或重新生成包含 Key 的配对码";
    }
    private boolean restoreComputer() {
        if (reconnectPaused || busy || testControl != null || invitation.length() > 0) return false;
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
                startMulti(routes.toString(), pin, null, credential, resume);
            }
            else if (!pin.isEmpty()) startDirect(address, pin, resume);
            else { endpoint = address; token = credential; paired = true; restoring = true; enabled = true; startNetwork(); }
            return true;
        } catch (Exception e) { error.setText("无法读取保存的电脑凭据，请重新配对"); render(); return false; }
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
                        codeView.setText(code); render(); pollApproval();
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
                    try { if (!BuildConfig.TESTING || fingerprint != null) { ConnectionStore.save(this, endpoint, token, fingerprint, connectionRoutes); rememberedComputer = true; } claimID = null; paired = true; openWeb(); }
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
                Androidnet.setInterfaces(interfaceSnapshot());
                JSONObject status = response(client.request(address, "/v1/status", "GET", credential, ""));
                if (!"WeQ Remote".equals(status.getString("product")) || status.getInt("protocol") != 1 || !"status:read".equals(status.getString("scope")) || !status.getBoolean("online")) throw new Exception("电脑返回了不兼容的数据");
                boolean webReady = client.hasWeb();
                main.post(() -> {
                    if (revision != generation || !credential.equals(token)) return;
                    if (updatingConnection) {
                        try { ConnectionStore.save(this, endpoint, credential, fingerprint, connectionRoutes); updatingConnection = false; }
                        catch (Exception e) { fail(revision, "无法保存新的电脑地址，请重试"); return; }
                    }
                    busy = false; render();
                    if (WebStartup.shouldOpenWeb(restoring, webView != null, webReady)) { restoring = false; if (visible) openWeb(); }
                });
            } catch (Exception e) { fail(revision, e.getMessage()); }
        });
    }
    private void openWeb() {
        final Client client = node; final int revision = generation;
        final String address = endpoint, credential = token, localSecret = Invitation.credential();
        busy = true; webLoaded = false; webStartupProblem = null; webLoadingStage = "正在准备网页连接"; computerState.setText(webLoadingStage); render();
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
                            if (webFeatures != null) { webFeatures.close(); webFeatures = null; }
                            if (webView != null) { webView.stopLoading(); webView.destroy(); }
                            webView = new android.webkit.WebView(this);
                            final android.webkit.WebView page = webView;
                            android.webkit.WebSettings settings = webView.getSettings();
                            settings.setJavaScriptEnabled(true); settings.setDomStorageEnabled(true);
                            settings.setUserAgentString(settings.getUserAgentString() + " WeQRemote");
                            settings.setAllowFileAccess(false); settings.setAllowContentAccess(false);
                            settings.setMixedContentMode(android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW);
                            cookies.setAcceptThirdPartyCookies(webView, false);
                            webFeatures = new WebFeatures(this, webView, origin);
                            webView.setWebViewClient(new android.webkit.WebViewClient() {
                                private boolean allowed(Uri url) { return "http".equals(url.getScheme()) && "127.0.0.1".equals(url.getHost()) && url.getPort() == Uri.parse(origin).getPort(); }
                                @Override public void onPageStarted(android.webkit.WebView view, String url, android.graphics.Bitmap icon) {
                                    if (webView != page) return;
                                    webDownload = null; webStartupReported = false;
                                    if (!webLoaded) { webLoadingStage = "正在下载网页资源"; render(); }
                                    main.removeCallbacks(webStartupTimeout);
                                    main.postDelayed(webStartupTimeout, 45000);
                                }
                                @Override public void onPageCommitVisible(android.webkit.WebView view, String url) {
                                    if (webView == page && !webLoaded) { webLoadingStage = "正在下载网页资源"; render(); }
                                    // 不等待图片等尾部资源完成，尽早订阅并补读网页已经发出的启动状态。
                                    if (webView == page && allowed(Uri.parse(url)) && webFeatures != null) webFeatures.observeStartup();
                                }
                                @Override public void onPageFinished(android.webkit.WebView view, String url) {
                                    if (view != page || webView != page || !allowed(Uri.parse(url))) return;
                                    if (webFeatures != null) webFeatures.pageReady();
                                }
                                @Override public void onReceivedError(android.webkit.WebView view, android.webkit.WebResourceRequest request, android.webkit.WebResourceError error) {
                                    if (webView == page && request.isForMainFrame() && !webLoaded) failWebLoad("无法加载 WeQ 页面，请检查电脑与网络后重试。");
                                    else if (webView == page && allowed(request.getUrl()) && !webLoaded) recordWebResourceFailure(page, request.getUrl().getPath(), 0);
                                }
                                @Override public void onReceivedHttpError(android.webkit.WebView view, android.webkit.WebResourceRequest request, android.webkit.WebResourceResponse response) {
                                    if (webView == page && request.isForMainFrame() && !webLoaded && response.getStatusCode() >= 400)
                                        failWebLoad("无法加载 WeQ 页面，请检查电脑与网络后重试。");
                                    else if (webView == page && allowed(request.getUrl()) && !webLoaded && response.getStatusCode() >= 400)
                                        recordWebResourceFailure(page, request.getUrl().getPath(), response.getStatusCode());
                                }
                                @Override public boolean shouldOverrideUrlLoading(android.webkit.WebView view, android.webkit.WebResourceRequest request) { return request.isForMainFrame() ? webFeatures == null || webFeatures.navigate(request.getUrl()) : !allowed(request.getUrl()); }
                                @Override public android.webkit.WebResourceResponse shouldInterceptRequest(android.webkit.WebView view, android.webkit.WebResourceRequest request) {
                                    if (allowed(request.getUrl())) return null;
                                    return new android.webkit.WebResourceResponse("text/plain", "UTF-8", 403, "Forbidden", java.util.Collections.emptyMap(), new java.io.ByteArrayInputStream(new byte[0]));
                                }
                            });
                            // 网页铺满整屏，不再显示任何原生栏或按钮；未加载完时用连接页盖在上面显示进度。
                            LinearLayout shell = new LinearLayout(this); shell.setOrientation(LinearLayout.VERTICAL); shell.setBackgroundColor(webBackgroundColor());
                            shell.addView(webView, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.MATCH_PARENT));
                            if (android.os.Build.VERSION.SDK_INT >= 30 && !webViewHandlesSafeArea()) applyWebInsets(shell);
                            android.widget.FrameLayout root = new android.widget.FrameLayout(this);
                            android.view.ViewGroup parent = (android.view.ViewGroup) setupView.getParent();
                            if (parent != null) parent.removeView(setupView);
                            root.addView(shell, new android.widget.FrameLayout.LayoutParams(-1, -1));
                            root.addView(setupView, new android.widget.FrameLayout.LayoutParams(-1, -1));
                            setContentView(root); render();
                            webView.loadUrl(origin + "/");
                        });
                    });
                });
            } catch (Exception e) { fail(revision, "无法打开 WeQ Web，请检查电脑上的 Web 服务"); }
        });
    }
    void receiveWebStartup(android.webkit.WebView page, String state, String message) {
        if (webView != page || webLoaded) return;
        webStartupReported = true;
        if ("loading".equals(state)) {
            webLoadingStage = message == null || message.isEmpty() ? "正在初始化 WeQ 页面" : message.substring(0, Math.min(message.length(), 100));
            render();
        } else if ("ready".equals(state) || "action-required".equals(state)) showWebPage();
        else if ("error".equals(state)) failWebLoad(message == null || message.isEmpty() ? "WeQ 页面启动失败，请重试。" : message.substring(0, Math.min(message.length(), 500)));
    }
    void receiveWebDownload(android.webkit.WebView page, WebDownloadProgress value) {
        if (webView != page || webLoaded) return;
        webDownload = value;
        if (!webStartupReported) webLoadingStage = value.downloading() ? "正在下载网页资源" : "正在执行网页脚本";
        render();
    }
    void recordWebConsoleFailure(android.webkit.WebView page, String message) {
        if (webView != page || webLoaded) return;
        String problem = WebStartup.consoleProblem(message);
        if (problem != null) webStartupProblem = problem;
    }
    private void recordWebResourceFailure(android.webkit.WebView page, String path, int status) {
        if (webView != page || webLoaded) return;
        String problem = WebStartup.resourceProblem(path, status);
        if (problem != null) failWebLoad(problem);
    }
    private void showWebPage() {
        if (webLoaded) return;
        main.removeCallbacks(webStartupTimeout);
        webLoaded = true;
        android.view.ViewGroup parent = (android.view.ViewGroup) setupView.getParent();
        if (parent != null) {
            if (android.animation.ValueAnimator.areAnimatorsEnabled())
                setupView.animate().alpha(0).setDuration(180).withEndAction(() -> { if (setupView.getParent() == parent && webLoaded) parent.removeView(setupView); setupView.setAlpha(1); }).start();
            else parent.removeView(setupView);
        }
        render();
    }
    private void failWebLoad(String message) {
        final android.webkit.WebView failedPage = webView;
        main.post(() -> {
            if (webView == null || webView != failedPage || webLoaded) return;
            busy = false; paired = false; restoring = false; webLoaded = false;
            closeWeb();
            error.setText(message); render();
        });
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
            android.graphics.Rect bars = WindowInsetsHelper.contentInsets(insets);
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom);
            return insets;
        });
        shell.requestApplyInsets();
    }
    private void closeWeb() {
        main.removeCallbacks(webStartupTimeout);
        webLoaded = false;
        webDownload = null;
        if (webFeatures != null) { webFeatures.close(); webFeatures = null; }
        Client active = node;
        if (active != null) worker.execute(active::closeWeb);
        if (webView == null) return;
        webView.stopLoading(); webView.loadUrl("about:blank"); webView.clearHistory(); webView.destroy(); webView = null;
        android.webkit.CookieManager.getInstance().removeAllCookies(null);
        android.view.ViewGroup parent = (android.view.ViewGroup) setupView.getParent();
        if (parent != null) parent.removeView(setupView);
        setContentView(setupView);
        render();
    }
    @Override public void onBackPressed() {
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
        if (status == 401) throw new Exception("设备未授权或授权已被撤销，请重新配对");
        if (status < 200 || status >= 300) throw new Exception("电脑返回 HTTP " + status + "，请检查邀请是否有效");
        return new JSONObject(envelope.getString("body"));
    }
    private void fail(int revision, String message) { main.post(() -> {
        if (revision != generation) return;
        boolean revoked = "设备未授权或授权已被撤销，请重新配对".equals(message);
        if (!revoked && webView != null) {
            // 全屏网页不弹原生提示；页面自己显示重连状态，壳只静默重试。
            busy = false;
            main.removeCallbacks(reconnectPoll);
            if (visible) main.postDelayed(reconnectPoll, 5000);
            return;
        }
        if (revoked && !updatingConnection) { ConnectionStore.delete(this); rememberedComputer = false; Androidnet.clearWebCache(); }
        boolean updateFailed = updatingConnection;
        stopNetwork(true); error.setText(message == null ? "连接失败，请重试" : message); render();
        if (updateFailed) { reconnectPaused = true; return; }
        if (!BuildConfig.TESTING && visible) main.postDelayed(reconnectPoll, 5000);
    }); }
    @Override protected void onActivityResult(int request, int result, Intent data) { super.onActivityResult(request, result, data); if (webFeatures != null && webFeatures.result(request, result, data)) return; if (request == 7 && result == RESULT_OK && data != null) { invitation.setText(data.getStringExtra("invitation")); main.post(this::pair); } }
    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(request, permissions, results);
        if (request == WebFeatures.MEDIA && webFeatures != null) webFeatures.grantMedia();
    }
}
