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
    @Override public void onCreate(Bundle arguments) { super.onCreate(arguments); lan = "1".equals(arguments.getString("lan")); start(); }
    @Override public void onStart() {
        Bundle result = new Bundle();
        MainActivity activity = null;
        try {
            String pkg = getTargetContext().getPackageName();
            ConnectionStore.delete(getTargetContext());
            Intent first = new Intent().setComponent(new ComponentName(pkg, MainActivity.class.getName())).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            activity = (MainActivity)startActivitySync(first);
            final MainActivity initial = activity;
            require(read(initial.networkState).contains("未启动"), "default network must stay off");
            runOnMainSync(() -> require(!initial.pairButton.isEnabled(), "unconnected pairing enabled"));
            saveScreenshot("pairing.png");
            runOnMainSync(initial::finish); waitForIdleSync();

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
            require(ConnectionStore.load(getTargetContext()) != null, "credential not persisted");
            runOnMainSync(paired::finish); waitForIdleSync();
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
            runOnMainSync(restored::finish); waitForIdleSync();
            current = (MainActivity)startActivitySync(new Intent().setComponent(new ComponentName(pkg, MainActivity.class.getName())).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            waitText(current.error, "授权已被撤销", 45000);
            require(ConnectionStore.load(getTargetContext()) == null, "revoked credential not removed");
        } finally { if (current != null) { MainActivity last = current; runOnMainSync(last::finish); } ConnectionStore.delete(getTargetContext()); }
    }
    private String read(android.widget.TextView view) { AtomicReference<String> value = new AtomicReference<>(); runOnMainSync(() -> value.set(view.getText().toString())); return value.get(); }
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
        while (android.os.SystemClock.elapsedRealtime() < until) {
            AtomicReference<String> text = new AtomicReference<>("");
            java.util.concurrent.CountDownLatch ready = new java.util.concurrent.CountDownLatch(1);
            runOnMainSync(() -> {
                if (activity.webView == null) { ready.countDown(); return; }
                activity.webView.evaluateJavascript("document.body.innerText", value -> { text.set(value); ready.countDown(); });
            });
            require(ready.await(5, java.util.concurrent.TimeUnit.SECONDS), "WebView evaluation timeout");
            if (text.get().contains(expected)) return;
            Thread.sleep(200);
        }
        throw new AssertionError("WebView state not reached: " + expected);
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
