package io.github.weqdevs.remote;

import android.app.Instrumentation;
import android.content.ComponentName;
import android.content.Intent;
import android.graphics.Bitmap;
import android.os.Bundle;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.concurrent.atomic.AtomicReference;
import org.json.JSONObject;

public final class RemoteInstrumentation extends Instrumentation {
    private boolean lan;
    private boolean uiOnly;
    private boolean surfacesOnly;
    @Override public void onCreate(Bundle arguments) { super.onCreate(arguments); lan = "1".equals(arguments.getString("lan")); uiOnly = "1".equals(arguments.getString("ui")); surfacesOnly = "1".equals(arguments.getString("surfaces")); start(); }
    @Override public void onStart() {
        Bundle result = new Bundle();
        MainActivity activity = null;
        try {
            String pkg = getTargetContext().getPackageName();
            if (surfacesOnly) {
                testWebSurfaces(pkg);
                result.putString("stream", "PASS: full screen callback once; close releases surface; orientation retains Activity\n");
                finish(android.app.Activity.RESULT_OK, result); return;
            }
            if (uiOnly) {
                testDetailsMenu(pkg);
                result.putString("stream", "PASS: home details menu; system and app version; persistent prerelease toggle\n");
                finish(android.app.Activity.RESULT_OK, result); return;
            }
            ConnectionStore.delete(getTargetContext());
            Intent first = new Intent().setComponent(new ComponentName(pkg, MainActivity.class.getName())).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            activity = (MainActivity)startActivitySync(first);
            final MainActivity initial = activity;
            require(read(initial.networkState).contains("未启动"), "default network must stay off");
            runOnMainSync(() -> require(!initial.pairButton.isEnabled(), "unconnected pairing enabled"));
            saveScreenshot("pairing.png");
            finishActivity(initial);

            if (lan) { testLAN(pkg); result.putString("stream", "PASS: LAN pinned TLS; Keystore persisted reconnect; WebView HTTP; WebSocket; revoke and credential removal\n"); finish(android.app.Activity.RESULT_OK, result); return; }

            JSONObject network = http("/test/network", "GET");
            JSONObject invitation = http("/test/invitation", "GET");
            Intent launch = new Intent().setComponent(new ComponentName(pkg, MainActivity.class.getName())).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra("isolated_ts_test", true).putExtra("test_control", network.getString("control")).putExtra("test_invitation", invitation.getString("url"));
            activity = (MainActivity)startActivitySync(launch);
            final MainActivity connected = activity;
            waitText(connected.networkState, "已连接", 40000);
            runOnMainSync(() -> connected.pairButton.performClick());
            waitWeb(connected, "Web 已连接", 30000);
            waitWeb(connected, "WebSocket 已连接", 15000);
            checkBackgroundResume(connected);
            runOnMainSync(() -> connected.webView.evaluateJavascript("document.querySelector('#probe').click()", null));
            waitWeb(connected, "Web 已连接", 15000);
            android.view.accessibility.AccessibilityNodeInfo activeWindow = null;
            long windowDeadline = android.os.SystemClock.elapsedRealtime() + 5000;
            while (android.os.SystemClock.elapsedRealtime() < windowDeadline) {
                activeWindow = getUiAutomation().getRootInActiveWindow();
                if (activeWindow != null && pkg.contentEquals(activeWindow.getPackageName())) break;
                Thread.sleep(100);
            }
            if (activeWindow == null || !pkg.contentEquals(activeWindow.getPackageName())) {
                Bitmap failureImage = getUiAutomation().takeScreenshot();
                if (failureImage != null) { try (FileOutputStream output = new FileOutputStream(new File(getTargetContext().getFilesDir(), "failure.png"))) { failureImage.compress(Bitmap.CompressFormat.PNG, 100, output); } failureImage.recycle(); }
                throw new AssertionError("active window mismatch: expected=" + pkg + ", observed=" + (activeWindow == null ? "none" : activeWindow.getPackageName()));
            }
            Bitmap image = getUiAutomation().takeScreenshot();
            require(image != null, "screenshot unavailable");
            try (FileOutputStream output = new FileOutputStream(new File(getTargetContext().getFilesDir(), "connection.png"))) { image.compress(Bitmap.CompressFormat.PNG, 100, output); }
            image.recycle();
            http("/test/revoke", "POST");
            waitWeb(connected, "订阅已断开", 20000);
            waitWeb(connected, "授权已撤销", 20000);
            result.putString("stream", "PASS: default network off; embedded TS; pairing; WebView HTTP; WebSocket; revoke=403 and socket closed\n");
            runOnMainSync(connected::finish);
            finish(android.app.Activity.RESULT_OK, result);
        } catch (Throwable failure) {
            if (activity != null) { MainActivity previous = activity; runOnMainSync(previous::finish); }
            result.putString("stream", "FAIL: " + failure.getClass().getSimpleName() + ": " + failure.getMessage() + "\n");
            finish(android.app.Activity.RESULT_CANCELED, result);
        }
    }
    private void testWebSurfaces(String pkg) throws Exception {
        MainActivity activity = (MainActivity) startActivitySync(new Intent().setComponent(new ComponentName(pkg, MainActivity.class.getName())).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        try {
            runOnMainSync(() -> {
                android.webkit.WebView page = new android.webkit.WebView(activity);
                WebFeatures features = new WebFeatures(activity, page, "http://127.0.0.1:7691");
                android.view.View surface = new android.view.View(activity);
                int[] finished = {0};
                features.onShowCustomView(surface, () -> finished[0]++);
                require(surface.getParent() != null, "full screen view not attached");
                require(features.exitFullscreen(), "full screen exit not consumed");
                require(!features.exitFullscreen(), "full screen exited twice");
                require(finished[0] == 1 && surface.getParent() == null, "full screen callback not exactly once");
                features.onShowCustomView(surface, () -> finished[0]++);
                features.close(); features.close();
                require(finished[0] == 2 && surface.getParent() == null, "close leaked full screen view");
                page.destroy();
                activity.setRequestedOrientation(android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE);
            });
            long deadline = android.os.SystemClock.elapsedRealtime() + 5000;
            while (activity.getResources().getConfiguration().orientation != android.content.res.Configuration.ORIENTATION_LANDSCAPE && android.os.SystemClock.elapsedRealtime() < deadline) Thread.sleep(100);
            require(!activity.isDestroyed(), "rotation destroyed Activity");
            require(activity.getResources().getConfiguration().orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE, "rotation did not occur");
        } finally { finishActivity(activity); }
    }
    private void testDetailsMenu(String pkg) throws Exception {
        MainActivity activity = (MainActivity) startActivitySync(new Intent().setComponent(new ComponentName(pkg, MainActivity.class.getName())).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        try {
            MainActivity initial = activity;
            saveScreenshot("home-ui.png");
            runOnMainSync(() -> find(initial.getWindow().getDecorView(), "更多").performClick());
            waitForIdleSync();
            android.view.accessibility.AccessibilityNodeInfo root = getUiAutomation().getRootInActiveWindow();
            require(!root.findAccessibilityNodeInfosByText("Tailscale：").isEmpty(), "missing Tailscale status");
            require(!root.findAccessibilityNodeInfosByText("Android ").isEmpty(), "missing system version");
            require(!root.findAccessibilityNodeInfosByText("检查更新").isEmpty(), "missing update action");
            java.util.List<android.view.accessibility.AccessibilityNodeInfo> switches = root.findAccessibilityNodeInfosByText("检查测试版");
            require(!switches.isEmpty(), "missing prerelease switch");
            boolean original = switches.get(0).isChecked();
            switches.get(0).performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK);
            waitForIdleSync(); saveScreenshot("details-ui.png");
            boolean stored = activity.getPreferences(0).getBoolean("checkPrerelease", false);
            require(stored != original, "preference not saved");
            getUiAutomation().performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK);
            waitForIdleSync();
            runOnMainSync(activity::finish); waitForIdleSync();
            long destroyedDeadline = android.os.SystemClock.elapsedRealtime() + 5000;
            while (!initial.isDestroyed() && android.os.SystemClock.elapsedRealtime() < destroyedDeadline) Thread.sleep(100);
            require(initial.isDestroyed(), "previous Activity did not finish");
            MainActivity reopened = (MainActivity) startActivitySync(new Intent().setComponent(new ComponentName(pkg, MainActivity.class.getName())).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            activity = reopened;
            long focusDeadline = android.os.SystemClock.elapsedRealtime() + 5000;
            while (!reopened.hasWindowFocus() && android.os.SystemClock.elapsedRealtime() < focusDeadline) Thread.sleep(100);
            require(reopened.hasWindowFocus() && !reopened.isFinishing(), "reopened Activity not ready");
            runOnMainSync(() -> find(reopened.getWindow().getDecorView(), "更多").performClick());
            waitForIdleSync();
            switches = getUiAutomation().getRootInActiveWindow().findAccessibilityNodeInfosByText("检查测试版");
            require(switches.get(0).isChecked() == stored, "preference lost after reopen");
            switches.get(0).performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK);
            waitForIdleSync();
        } finally { MainActivity last = activity; runOnMainSync(last::finish); }
    }
    private android.view.View find(android.view.View view, String description) {
        if (view.getContentDescription() != null && description.contentEquals(view.getContentDescription())) return view;
        if (view instanceof android.view.ViewGroup) {
            android.view.ViewGroup group = (android.view.ViewGroup) view;
            for (int i = 0; i < group.getChildCount(); i++) { android.view.View result = find(group.getChildAt(i), description); if (result != null) return result; }
        }
        return null;
    }
    private void testLAN(String pkg) throws Exception {
        MainActivity current = null;
        try {
            JSONObject invitation = http("/test/invitation", "GET");
            Intent first = new Intent().setComponent(new ComponentName(pkg, MainActivity.class.getName())).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).setData(android.net.Uri.parse(invitation.getString("url")));
            current = (MainActivity)startActivitySync(first);
            MainActivity paired = current;
            runOnMainSync(() -> paired.pairButton.performClick());
            waitWeb(paired, "Web 已连接", 30000); waitWeb(paired, "WebSocket 已连接", 15000);
            checkBackgroundResume(paired);
            checkConnectionFeedback(paired);
            require(ConnectionStore.load(getTargetContext()) != null, "credential not persisted");
            finishActivity(paired);
            current = (MainActivity)startActivitySync(new Intent().setComponent(new ComponentName(pkg, MainActivity.class.getName())).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            MainActivity restored = current;
            waitWeb(restored, "Web 已连接", 30000); waitWeb(restored, "WebSocket 已连接", 15000);
            require(http("/test/devices", "GET").getInt("count") == 1, "reconnect created a new pairing");
            JSONObject beforeUpdate = ConnectionStore.load(getTargetContext());
            JSONObject refreshedInvitation = http("/test/invitation", "GET");
            Intent update = new Intent().setData(android.net.Uri.parse(refreshedInvitation.getString("url")));
            runOnMainSync(() -> restored.onNewIntent(update));
            waitForIdleSync();
            waitWeb(restored, "Web 已连接", 30000); waitWeb(restored, "WebSocket 已连接", 15000);
            require(beforeUpdate.getString("token").equals(ConnectionStore.load(getTargetContext()).getString("token")), "address update replaced approved token");
            require(http("/test/devices", "GET").getInt("count") == 1, "address update requested a new pairing");
            android.view.accessibility.AccessibilityNodeInfo active = null;
            long deadline = android.os.SystemClock.elapsedRealtime() + 5000;
            while (android.os.SystemClock.elapsedRealtime() < deadline) {
                active = getUiAutomation().getRootInActiveWindow();
                if (active != null && pkg.contentEquals(active.getPackageName())) break;
                Thread.sleep(100);
            }
            if (active == null || !pkg.contentEquals(active.getPackageName())) {
                Bitmap failure = getUiAutomation().takeScreenshot();
                if (failure != null) { try (FileOutputStream output = new FileOutputStream(new File(getTargetContext().getFilesDir(), "failure.png"))) { failure.compress(Bitmap.CompressFormat.PNG, 100, output); } failure.recycle(); }
                throw new AssertionError("test window not foreground: " + (active == null ? "none" : active.getPackageName()));
            }
            Bitmap image = getUiAutomation().takeScreenshot(); require(image != null, "screenshot unavailable");
            try (FileOutputStream output = new FileOutputStream(new File(getTargetContext().getFilesDir(), "connection.png"))) { image.compress(Bitmap.CompressFormat.PNG, 100, output); } image.recycle();
            http("/test/revoke", "POST");
            waitWeb(restored, "订阅已断开", 20000); waitWeb(restored, "授权已撤销", 20000);
            finishActivity(restored);
            current = (MainActivity)startActivitySync(new Intent().setComponent(new ComponentName(pkg, MainActivity.class.getName())).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            waitText(current.error, "授权已被撤销", 45000);
            require(ConnectionStore.load(getTargetContext()) == null, "revoked credential not removed");
        } finally { if (current != null) { MainActivity last = current; runOnMainSync(last::finish); } ConnectionStore.delete(getTargetContext()); }
    }
    private String read(android.widget.TextView view) { AtomicReference<String> value = new AtomicReference<>(); runOnMainSync(() -> value.set(view.getText().toString())); return value.get(); }
    private void finishActivity(MainActivity activity) throws Exception {
        runOnMainSync(activity::finish); waitForIdleSync();
        long deadline = android.os.SystemClock.elapsedRealtime() + 5000;
        while (!activity.isDestroyed() && android.os.SystemClock.elapsedRealtime() < deadline) Thread.sleep(100);
        require(activity.isDestroyed(), "Activity did not finish");
    }
    private void checkConnectionFeedback(MainActivity activity) throws Exception {
        java.lang.reflect.Field healthField = MainActivity.class.getDeclaredField("health"); healthField.setAccessible(true);
        java.lang.reflect.Field generationField = MainActivity.class.getDeclaredField("generation"); generationField.setAccessible(true);
        java.lang.reflect.Field busyField = MainActivity.class.getDeclaredField("busy"); busyField.setAccessible(true);
        java.lang.reflect.Field loadedField = MainActivity.class.getDeclaredField("webLoaded"); loadedField.setAccessible(true);
        java.lang.reflect.Field warningField = MainActivity.class.getDeclaredField("connectionWarning"); warningField.setAccessible(true);
        java.lang.reflect.Method fail = MainActivity.class.getDeclaredMethod("fail", int.class, String.class); fail.setAccessible(true);
        java.lang.reflect.Method verify = MainActivity.class.getDeclaredMethod("verify"); verify.setAccessible(true);
        long deadline = android.os.SystemClock.elapsedRealtime() + 20000;
        while ((busyField.getBoolean(activity) || !loadedField.getBoolean(activity) || !activity.hasWindowFocus()) && android.os.SystemClock.elapsedRealtime() < deadline) Thread.sleep(100);
        require(!busyField.getBoolean(activity) && loadedField.getBoolean(activity) && activity.hasWindowFocus(), "page verification not ready");
        android.webkit.WebView original = activity.webView;
        // 注入请求失败回调以检查原生反馈；恢复阶段仍调用真实夹具状态接口。
        for (int count = 1; count <= 2; count++) {
            runOnMainSync(() -> {
                try { fail.invoke(activity, generationField.getInt(activity), "synthetic connection failure"); }
                catch (Exception problem) { throw new AssertionError(problem); }
            });
            waitForIdleSync();
            require(((ConnectionHealth) healthField.get(activity)).suspected == (count == 2), "transient failure threshold incorrect at " + count + ", loaded=" + loadedField.getBoolean(activity));
        }
        require(((android.view.View) warningField.get(activity)).getVisibility() == android.view.View.VISIBLE, "missing warning banner");
        saveScreenshot("connection-warning.png");
        runOnMainSync(() -> {
            try { verify.invoke(activity); } catch (Exception problem) { throw new AssertionError(problem); }
        });
        deadline = android.os.SystemClock.elapsedRealtime() + 20000;
        while (((ConnectionHealth) healthField.get(activity)).suspected && android.os.SystemClock.elapsedRealtime() < deadline) Thread.sleep(100);
        require(!((ConnectionHealth) healthField.get(activity)).suspected, "warning did not clear after successful check");
        require(activity.webView == original, "feedback replaced the page");
        require(((android.view.View) warningField.get(activity)).getVisibility() == android.view.View.GONE, "recovered banner still visible");
        saveScreenshot("connection-recovered.png");
    }
    private void checkBackgroundResume(MainActivity activity) throws Exception {
        AtomicReference<android.webkit.WebView> original = new AtomicReference<>();
        java.util.concurrent.CountDownLatch ready = new java.util.concurrent.CountDownLatch(1);
        runOnMainSync(() -> {
            original.set(activity.webView);
            activity.webView.evaluateJavascript("window.__weqResumeMarker='retained'; document.body.insertAdjacentHTML('beforeend','<p id=resume-marker>页面状态已保留</p>')", ignored -> ready.countDown());
        });
        require(ready.await(5, java.util.concurrent.TimeUnit.SECONDS), "resume marker not set");
        try (java.io.InputStream output = new android.os.ParcelFileDescriptor.AutoCloseInputStream(getUiAutomation().executeShellCommand("input keyevent KEYCODE_HOME"))) { while (output.read() != -1) { } }
        Thread.sleep(1500);
        getTargetContext().startActivity(new Intent().setComponent(new ComponentName(getTargetContext(), MainActivity.class))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT));
        long deadline = android.os.SystemClock.elapsedRealtime() + 5000;
        while (!activity.hasWindowFocus() && android.os.SystemClock.elapsedRealtime() < deadline) Thread.sleep(100);
        require(activity.hasWindowFocus(), "background return not foreground");
        waitWeb(activity, "页面状态已保留", 15000);
        runOnMainSync(() -> require(activity.webView == original.get(), "background return replaced WebView"));
        require(http("/test/devices", "GET").getInt("count") == 1, "background return created another pairing");
    }
    private void saveScreenshot(String name) throws Exception {
        Bitmap image = getUiAutomation().takeScreenshot(); require(image != null, "screenshot unavailable");
        try (FileOutputStream output = new FileOutputStream(new File(getTargetContext().getFilesDir(), name))) { image.compress(Bitmap.CompressFormat.PNG, 100, output); }
        image.recycle();
    }
    private void waitWeb(MainActivity activity, String expected, long timeout) throws Exception {
        long until = android.os.SystemClock.elapsedRealtime() + timeout;
        String lastText = "";
        while (android.os.SystemClock.elapsedRealtime() < until) {
            AtomicReference<String> text = new AtomicReference<>("");
            java.util.concurrent.CountDownLatch ready = new java.util.concurrent.CountDownLatch(1);
            runOnMainSync(() -> {
                if (activity.webView == null) { ready.countDown(); return; }
                activity.webView.evaluateJavascript("document.body.innerText", value -> { text.set(value); ready.countDown(); });
            });
            require(ready.await(5, java.util.concurrent.TimeUnit.SECONDS), "WebView evaluation timeout");
            lastText = text.get();
            if (text.get().contains(expected)) return;
            Thread.sleep(200);
        }
        saveScreenshot("failure-web.png");
        throw new AssertionError("WebView state not reached: " + expected + "; home=" + read(activity.computerState)
            + "; error=" + read(activity.error) + "; web=" + lastText.substring(0, Math.min(150, lastText.length())));
    }
    private void waitText(android.widget.TextView view, String expected, long timeout) throws Exception {
        long until = android.os.SystemClock.elapsedRealtime() + timeout;
        while (android.os.SystemClock.elapsedRealtime() < until) { if (read(view).contains(expected)) return; Thread.sleep(200); }
        String last = read(view);
        if (!last.contains(expected)) throw new AssertionError("UI state not reached: " + expected + "; current=" + last);
    }
    private JSONObject http(String path, String method) throws Exception {
        HttpURLConnection connection = (HttpURLConnection)new URL("http://127.0.0.1:45198" + path).openConnection();
        connection.setRequestMethod(method); connection.setConnectTimeout(5000); connection.setReadTimeout(5000);
        try {
            int status = connection.getResponseCode();
            require(status >= 200 && status < 300, "fixture HTTP " + status);
            if (status == 204) return new JSONObject();
            try (java.io.InputStream input = connection.getInputStream(); ByteArrayOutputStream bytes = new ByteArrayOutputStream()) {
                byte[] chunk = new byte[1024]; int count;
                while ((count = input.read(chunk)) != -1) { bytes.write(chunk, 0, count); require(bytes.size() <= 65536, "fixture response too large"); }
                return new JSONObject(bytes.toString("UTF-8"));
            }
        } finally { connection.disconnect(); }
    }
    private static void require(boolean value, String message) { if (!value) throw new AssertionError(message); }
}
