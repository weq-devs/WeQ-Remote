package io.github.weqdevs.remote;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.webkit.CookieManager;
import android.webkit.PermissionRequest;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebView;
import android.widget.Toast;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** 当前 WebView 的文件选择、媒体授权和下载；随页面销毁而取消。 */
final class WebFeatures extends WebChromeClient {
    static final int FILE = 21, SAVE = 22, MEDIA = 23;
    private final Activity activity;
    private final WebView view;
    private final String origin;
    private final ExecutorService downloads = Executors.newSingleThreadExecutor();
    private ValueCallback<Uri[]> chooser;
    private PermissionRequest permission;
    private String downloadURL, downloadCookie;
    private java.io.File blobFile;
    private java.io.OutputStream blobOutput;
    private String blobToken;
    private String blobName = "download";
    private long blobOffset;
    private volatile HttpURLConnection connection;
    private volatile boolean closed;
    private volatile boolean saving;
    private final String resourceObserver;
    private final String connectionObserver;
    private android.view.View fullscreen;
    private CustomViewCallback fullscreenCallback;
    private int fullscreenSystemUi;
    private int fullscreenVisibleBars;

    WebFeatures(Activity activity, WebView view, String origin) {
        this.activity = activity; this.view = view; this.origin = origin;
        String script = "";
        try (InputStream input = activity.getAssets().open("web-startup-progress.js"); java.io.ByteArrayOutputStream output = new java.io.ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096]; int count;
            while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
            script = new String(output.toByteArray(), java.nio.charset.StandardCharsets.UTF_8);
        } catch (java.io.IOException ignored) { }
        resourceObserver = script;
        String healthScript = "";
        try (InputStream input = activity.getAssets().open("web-connection-health.js"); java.io.ByteArrayOutputStream output = new java.io.ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096]; int count;
            while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
            healthScript = new String(output.toByteArray(), java.nio.charset.StandardCharsets.UTF_8);
        } catch (java.io.IOException ignored) { }
        connectionObserver = healthScript;
        view.setWebChromeClient(this);
        view.addJavascriptInterface(new ExternalLinks(), "weqRemoteLinks");
        view.setDownloadListener((url, agent, disposition, mime, size) -> {
            if (closed || saving || downloadURL != null) return;
            if (url.startsWith("blob:") && WebAccess.sameOrigin(origin, url.substring(5))) {
                beginBlob(url, mime, "download"); return;
            }
            if (!WebAccess.sameOrigin(origin, url)) { message("该下载地址不能直接保存"); return; }
            downloadURL = url;
            downloadCookie = CookieManager.getInstance().getCookie(url);
            selectDestination(mime, android.webkit.URLUtil.guessFileName(url, disposition, mime));
        });
    }
    private void selectDestination(String mime, String name) {
        Intent intent = new Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
            .setType(mime == null || mime.isEmpty() ? "application/octet-stream" : mime)
            .putExtra(Intent.EXTRA_TITLE, WebAccess.fileName(name));
        try { activity.startActivityForResult(intent, SAVE); }
        catch (RuntimeException error) { clearPendingBlob(); downloadURL = null; downloadCookie = null; message("无法打开文件保存位置"); }
    }
    private synchronized void beginBlob(String url, String mime, String name) {
        try {
            blobFile = java.io.File.createTempFile("weq-download-", ".tmp", activity.getCacheDir());
            blobOutput = new java.io.FileOutputStream(blobFile);
            blobToken = java.util.UUID.randomUUID().toString(); blobOffset = 0;
            blobName = WebAccess.fileName(name);
            downloadURL = url;
            String token = org.json.JSONObject.quote(blobToken), address = org.json.JSONObject.quote(url);
            String type = org.json.JSONObject.quote(mime == null ? "application/octet-stream" : mime);
            view.evaluateJavascript("(async function(){var id=" + token + ";try{var r=await fetch(" + address + ");if(!r.ok||!r.body)throw Error();var reader=r.body.getReader(),offset=0;try{for(;;){var part=await reader.read();if(part.done)break;for(var i=0;i<part.value.length;i+=65536){var bytes=part.value.subarray(i,i+65536),text='';for(var j=0;j<bytes.length;j+=8192)text+=String.fromCharCode.apply(null,bytes.subarray(j,j+8192));if(!weqRemoteLinks.appendBlob(id,offset,btoa(text)))throw Error();offset+=bytes.length;}}}finally{await reader.cancel();}weqRemoteLinks.finishBlob(id," + type + ");}catch(e){weqRemoteLinks.cancelBlob(id);}})()", null);
        } catch (Exception error) { clearPendingBlob(); downloadURL = null; message("无法准备下载文件"); }
    }
    private synchronized void clearPendingBlob() {
        if (blobOutput != null) { try { blobOutput.close(); } catch (Exception ignored) { } blobOutput = null; }
        if (blobFile != null) { blobFile.delete(); blobFile = null; }
        blobToken = null; blobOffset = 0;
    }
    public final class ExternalLinks {
        @android.webkit.JavascriptInterface public void resources(String payload) {
            if (payload == null || payload.length() > 512) return;
            try {
                org.json.JSONObject value = new org.json.JSONObject(payload);
                WebDownloadProgress progress = new WebDownloadProgress(value.getInt("completed"), value.getInt("total"), value.getLong("loadedBytes"), value.getLong("totalBytes"));
                activity.runOnUiThread(() -> {
                    if (!closed && WebAccess.sameOrigin(origin, view.getUrl()) && activity instanceof MainActivity)
                        ((MainActivity) activity).receiveWebDownload(view, progress);
                });
            } catch (org.json.JSONException | IllegalArgumentException ignored) { }
        }
        @android.webkit.JavascriptInterface public void startup(String state, String message) {
            activity.runOnUiThread(() -> {
                if (!closed && WebAccess.sameOrigin(origin, view.getUrl()) && activity instanceof MainActivity)
                    ((MainActivity) activity).receiveWebStartup(view, state, message);
            });
        }
        @android.webkit.JavascriptInterface public void openMenu() {
            activity.runOnUiThread(() -> {
                if (!closed && WebAccess.sameOrigin(origin, view.getUrl()) && activity instanceof MainActivity)
                    ((MainActivity) activity).showConnectionMenu();
            });
        }
        @android.webkit.JavascriptInterface public void connectionFailed() {
            activity.runOnUiThread(() -> {
                if (!closed && WebAccess.sameOrigin(origin, view.getUrl()) && activity instanceof MainActivity)
                    ((MainActivity) activity).receiveConnectionFailure(view);
            });
        }
        @android.webkit.JavascriptInterface public void capture(String id) {
            if (id == null || !id.matches("[a-zA-Z0-9-]{1,64}")) return;
            activity.runOnUiThread(() -> {
                if (closed || saving || downloadURL != null) { captureResult(id, false); return; }
                android.graphics.Bitmap image = null;
                try {
                    int width = view.getWidth(), height = view.getHeight();
                    if (width <= 0 || height <= 0) throw new java.io.IOException("empty");
                    image = android.graphics.Bitmap.createBitmap(width, height, android.graphics.Bitmap.Config.ARGB_8888);
                    view.draw(new android.graphics.Canvas(image));
                    blobFile = java.io.File.createTempFile("weq-download-", ".png", activity.getCacheDir());
                    try (OutputStream output = new java.io.FileOutputStream(blobFile)) {
                        if (!image.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, output)) throw new java.io.IOException("encode");
                    }
                    downloadURL = "capture:" + id;
                    captureResult(id, true);
                    selectDestination("image/png", "WeQ-screenshot.png");
                } catch (Exception error) { clearPendingBlob(); downloadURL = null; captureResult(id, false); }
                finally { if (image != null) image.recycle(); }
            });
        }
        @android.webkit.JavascriptInterface public void open(String url) {
            activity.runOnUiThread(() -> { if (!closed) navigate(Uri.parse(url)); });
        }
        @android.webkit.JavascriptInterface public void downloadBlob(String url, String name) {
            activity.runOnUiThread(() -> {
                if (!closed && !saving && downloadURL == null && url.startsWith("blob:") && WebAccess.sameOrigin(origin, url.substring(5)))
                    beginBlob(url, java.net.URLConnection.guessContentTypeFromName(name), name);
            });
        }
        @android.webkit.JavascriptInterface public boolean appendBlob(String token, long offset, String base64) {
            synchronized (WebFeatures.this) {
                if (closed || blobToken == null || !blobToken.equals(token) || blobOutput == null || offset != blobOffset || base64.length() > 87384) return false;
                try {
                    byte[] bytes = android.util.Base64.decode(base64, android.util.Base64.NO_WRAP);
                    if (bytes.length == 0 || bytes.length > 65536 || blobOffset + bytes.length > 2L * 1024 * 1024 * 1024 || activity.getCacheDir().getUsableSpace() < bytes.length + 64L * 1024 * 1024) return false;
                    blobOutput.write(bytes); blobOffset += bytes.length;
                    return true;
                } catch (Exception ignored) { return false; }
            }
        }
        @android.webkit.JavascriptInterface public void finishBlob(String token, String mime) {
            synchronized (WebFeatures.this) {
                if (closed || blobToken == null || !blobToken.equals(token)) return;
                try { blobOutput.close(); blobOutput = null; }
                catch (Exception error) { cancelBlob(token); return; }
                blobToken = null;
                activity.runOnUiThread(() -> { if (!closed && blobFile != null) selectDestination(mime, blobName); });
            }
        }
        @android.webkit.JavascriptInterface public void cancelBlob(String token) {
            synchronized (WebFeatures.this) {
                if (blobToken == null || !blobToken.equals(token)) return;
                clearPendingBlob();
                activity.runOnUiThread(() -> { downloadURL = null; if (!closed) message("下载中断，请重新下载"); });
            }
        }
    }
    private void captureResult(String id, boolean ok) {
        if (closed) return;
        String detail = "{id:" + org.json.JSONObject.quote(id) + ",ok:" + ok + ",delivery:'native'" + (ok ? "" : ",error:'无法生成截图，请先完成当前下载'") + "}";
        view.evaluateJavascript("window.dispatchEvent(new CustomEvent('weq-remote-capture-result',{detail:" + detail + "}))", null);
    }
    void observeStartup() {
        if (!connectionObserver.isEmpty()) view.evaluateJavascript(connectionObserver, null);
        if (!resourceObserver.isEmpty()) view.evaluateJavascript(resourceObserver, null);
        if (closed) return;
        view.evaluateJavascript("(function(){function report(){var s=window.weqRemoteStartup;if(s)weqRemoteLinks.startup(s.state,s.message||'');}if(!window.__weqStartupListener){window.__weqStartupListener=true;window.addEventListener('weq-remote-startup',report);}report();})()", null);
    }
    @Override public boolean onConsoleMessage(android.webkit.ConsoleMessage message) {
        if (!closed && message.messageLevel() == android.webkit.ConsoleMessage.MessageLevel.ERROR && activity instanceof MainActivity)
            ((MainActivity) activity).recordWebConsoleFailure(view, message.message());
        return super.onConsoleMessage(message);
    }
    void pageReady() {
        if (closed) return;
        observeStartup();
        view.evaluateJavascript("window.weqRemoteConnection=window.weqRemoteConnection||{state:'connected'};window.weqRemoteShell={openMenu:function(){weqRemoteLinks.openMenu()},connectionFailed:function(){weqRemoteLinks.connectionFailed()}};window.dispatchEvent(new Event('weq-remote-shell-ready'));", null);
        view.evaluateJavascript("(function(){if(window.__weqRemoteLinks)return;window.__weqRemoteLinks=true;document.addEventListener('click',function(e){var a=e.target.closest&&e.target.closest('a[download]');if(a&&a.href.indexOf('blob:')===0){e.preventDefault();weqRemoteLinks.downloadBlob(a.href,a.download||'download');}},true);var original=window.open;window.open=function(url,target,features){if(url&&url!=='about:blank'){try{var parsed=new URL(url,location.href);if(parsed.origin!==location.origin){weqRemoteLinks.open(parsed.href);return null;}}catch(e){return null;}}return original.call(window,url,target,features);};})()", null);
    }
    void connectionState(String state, int recovery) {
        if (closed) return;
        view.evaluateJavascript("window.weqRemoteConnection={state:" + org.json.JSONObject.quote(state) + ",recovery:" + recovery + "};window.dispatchEvent(new Event('weq-remote-connection'));", null);
    }
    @Override public boolean onShowFileChooser(WebView web, ValueCallback<Uri[]> callback, FileChooserParams params) {
        cancelChooser();
        if (closed) { callback.onReceiveValue(null); return true; }
        chooser = callback;
        try { activity.startActivityForResult(params.createIntent().addCategory(Intent.CATEGORY_OPENABLE), FILE); }
        catch (RuntimeException error) { cancelChooser(); message("无法打开文件选择器"); }
        return true;
    }
    @Override @SuppressWarnings("deprecation") public void onShowCustomView(android.view.View content, CustomViewCallback callback) {
        if (closed) { callback.onCustomViewHidden(); return; }
        exitFullscreen();
        android.view.View decor = activity.getWindow().getDecorView();
        if (!(decor instanceof android.view.ViewGroup) || content.getParent() != null) {
            callback.onCustomViewHidden(); return;
        }
        fullscreen = content; fullscreenCallback = callback;
        fullscreenSystemUi = decor.getSystemUiVisibility();
        if (android.os.Build.VERSION.SDK_INT >= 30) {
            android.view.WindowInsets insets = decor.getRootWindowInsets();
            fullscreenVisibleBars = insets == null ? android.view.WindowInsets.Type.systemBars() :
                (insets.isVisible(android.view.WindowInsets.Type.statusBars()) ? android.view.WindowInsets.Type.statusBars() : 0) |
                (insets.isVisible(android.view.WindowInsets.Type.navigationBars()) ? android.view.WindowInsets.Type.navigationBars() : 0);
            android.view.WindowInsetsController controller = decor.getWindowInsetsController();
            if (controller != null) controller.hide(android.view.WindowInsets.Type.systemBars());
        } else decor.setSystemUiVisibility(fullscreenSystemUi | android.view.View.SYSTEM_UI_FLAG_FULLSCREEN |
            android.view.View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | android.view.View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
        ((android.view.ViewGroup) decor).addView(content, new android.view.ViewGroup.LayoutParams(-1, -1));
        content.requestFocus();
    }
    @Override public void onHideCustomView() { exitFullscreen(); }
    @SuppressWarnings("deprecation") boolean exitFullscreen() {
        android.view.View content = fullscreen;
        if (content == null) return false;
        CustomViewCallback callback = fullscreenCallback;
        fullscreen = null; fullscreenCallback = null;
        if (content.getParent() instanceof android.view.ViewGroup)
            ((android.view.ViewGroup) content.getParent()).removeView(content);
        android.view.View decor = activity.getWindow().getDecorView();
        if (android.os.Build.VERSION.SDK_INT >= 30) {
            android.view.WindowInsetsController controller = decor.getWindowInsetsController();
            if (controller != null && fullscreenVisibleBars != 0) controller.show(fullscreenVisibleBars);
        } else decor.setSystemUiVisibility(fullscreenSystemUi);
        if (callback != null) callback.onCustomViewHidden();
        view.requestFocus(); view.requestApplyInsets();
        return true;
    }
    @Override public void onPermissionRequest(PermissionRequest request) {
        if (closed || !WebAccess.sameOrigin(origin, request.getOrigin().toString())) { request.deny(); return; }
        if (permission != null) permission.deny();
        permission = request;
        ArrayList<String> missing = new ArrayList<>();
        for (String resource : request.getResources()) {
            String name = permissionName(resource);
            if (name != null && activity.checkSelfPermission(name) != PackageManager.PERMISSION_GRANTED && !missing.contains(name)) missing.add(name);
        }
        if (missing.isEmpty()) grantMedia();
        else activity.requestPermissions(missing.toArray(new String[0]), MEDIA);
    }
    @Override public void onPermissionRequestCanceled(PermissionRequest request) {
        if (permission == request) permission = null;
    }
    private String permissionName(String resource) {
        if (PermissionRequest.RESOURCE_AUDIO_CAPTURE.equals(resource)) return Manifest.permission.RECORD_AUDIO;
        if (PermissionRequest.RESOURCE_VIDEO_CAPTURE.equals(resource)) return Manifest.permission.CAMERA;
        return null;
    }
    void grantMedia() {
        PermissionRequest request = permission; permission = null;
        if (request == null) return;
        ArrayList<String> granted = new ArrayList<>();
        if (!closed && WebAccess.sameOrigin(origin, request.getOrigin().toString()))
            for (String resource : request.getResources()) {
                String name = permissionName(resource);
                if (name != null && activity.checkSelfPermission(name) == PackageManager.PERMISSION_GRANTED) granted.add(resource);
            }
        if (granted.isEmpty()) request.deny(); else request.grant(granted.toArray(new String[0]));
    }
    boolean result(int request, int result, Intent data) {
        if (request == FILE) {
            ValueCallback<Uri[]> callback = chooser; chooser = null;
            Uri[] values = FileChooserParams.parseResult(result, data);
            if (values != null) for (Uri uri : values)
                if (uri == null || !"content".equals(uri.getScheme())) { values = null; break; }
            if (callback != null) callback.onReceiveValue(closed ? null : values);
            return true;
        }
        if (request != SAVE) return false;
        String url = downloadURL, cookie = downloadCookie; downloadURL = null; downloadCookie = null;
        java.io.File blob;
        synchronized (this) { blob = blobFile; blobFile = null; }
        Uri destination = data == null ? null : data.getData();
        if (!closed && result == Activity.RESULT_OK && url != null && destination != null && "content".equals(destination.getScheme())) {
            saving = true;
            downloads.execute(() -> save(url, cookie, destination, blob));
        } else if (blob != null) blob.delete();
        return true;
    }
    private void save(String url, String cookie, Uri destination, java.io.File blob) {
        try {
            if (closed) throw new java.io.IOException("页面已关闭");
            HttpURLConnection request = null;
            if (blob == null) {
                request = (HttpURLConnection) new URL(url).openConnection();
                connection = request;
                request.setInstanceFollowRedirects(false);
                request.setConnectTimeout(15000); request.setReadTimeout(30000);
                if (cookie != null) request.setRequestProperty("Cookie", cookie);
                if (request.getResponseCode() != 200) throw new java.io.IOException("下载失败，请重新生成文件");
            }
            if (closed) throw new java.io.IOException("页面已关闭");
            try (InputStream input = blob == null ? request.getInputStream() : new java.io.FileInputStream(blob); OutputStream output = activity.getContentResolver().openOutputStream(destination, "w")) {
                if (output == null) throw new java.io.IOException("无法写入所选位置");
                byte[] buffer = new byte[65536]; int count;
                while ((count = input.read(buffer)) != -1) {
                    if (closed || Thread.currentThread().isInterrupted()) throw new java.io.IOException("下载已取消");
                    output.write(buffer, 0, count);
                }
            }
            activity.runOnUiThread(() -> message("文件已保存"));
        } catch (Exception error) {
            try { android.provider.DocumentsContract.deleteDocument(activity.getContentResolver(), destination); } catch (Exception ignored) { }
            activity.runOnUiThread(() -> { if (!closed) message("文件未保存，请重试下载"); });
        } finally {
            HttpURLConnection request = connection; connection = null;
            if (request != null) request.disconnect();
            if (blob != null) blob.delete();
            saving = false;
        }
    }
    boolean navigate(Uri uri) {
        String value = uri.toString();
        if (WebAccess.sameOrigin(origin, value)) return false;
        if (WebAccess.external(value)) {
            try { activity.startActivity(new Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE)); }
            catch (RuntimeException error) { message("没有可打开此链接的应用"); }
        }
        return true;
    }
    private void message(String text) { Toast.makeText(activity, text, Toast.LENGTH_LONG).show(); }
    private void cancelChooser() { if (chooser != null) { chooser.onReceiveValue(null); chooser = null; } }
    void close() {
        closed = true; exitFullscreen(); cancelChooser();
        if (permission != null) { permission.deny(); permission = null; }
        downloadURL = null; downloadCookie = null;
        clearPendingBlob();
        HttpURLConnection request = connection;
        if (request != null) request.disconnect();
        downloads.shutdown();
        view.setDownloadListener(null); view.setWebChromeClient(null);
        view.removeJavascriptInterface("weqRemoteLinks");
    }
}
