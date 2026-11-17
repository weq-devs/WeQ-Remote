package io.github.weqdevs.remote;

import java.util.Locale;

final class WebDownloadProgress {
    static final String LOADING_MESSAGE = "正在加载网页资源";
    final int completed, total;
    final long loadedBytes, totalBytes;
    final Long downloadedBytes;
    final long cachedBytes, unknownBytes;
    WebDownloadProgress(int completed, int total, long loadedBytes, long totalBytes) {
        this(completed, total, loadedBytes, totalBytes, null, 0, loadedBytes);
    }
    WebDownloadProgress(int completed, int total, long loadedBytes, long totalBytes, Long downloadedBytes, long cachedBytes, long unknownBytes) {
        if (total <= 0 || total > 4096 || completed < 0 || completed > total || totalBytes <= 0 || totalBytes > (1L << 40)
            || loadedBytes < 0 || loadedBytes > totalBytes || (completed == total) != (loadedBytes == totalBytes))
            throw new IllegalArgumentException("invalid resource progress");
        if (cachedBytes < 0 || cachedBytes > loadedBytes || unknownBytes < 0 || unknownBytes > loadedBytes - cachedBytes
            || (downloadedBytes == null ? cachedBytes != 0 || unknownBytes != loadedBytes : downloadedBytes < 0 || downloadedBytes > (1L << 40)))
            throw new IllegalArgumentException("invalid resource source progress");
        this.completed = completed; this.total = total; this.loadedBytes = loadedBytes; this.totalBytes = totalBytes;
        this.downloadedBytes = downloadedBytes; this.cachedBytes = cachedBytes; this.unknownBytes = unknownBytes;
    }
    float fraction() { return (float) loadedBytes / totalBytes; }
    static long number(Object value) {
        if (!(value instanceof Number)) throw new IllegalArgumentException("invalid progress number");
        double number = ((Number) value).doubleValue();
        if (number < 0 || number > (1L << 40) || number != Math.rint(number))
            throw new IllegalArgumentException("invalid progress number");
        return ((Number) value).longValue();
    }
    boolean downloading() { return completed < total; }
    boolean fullyCached() { return completed == total && downloadedBytes != null && downloadedBytes == 0 && cachedBytes == totalBytes && unknownBytes == 0; }
    String stage() { return downloading() ? LOADING_MESSAGE : "正在初始化网页"; }
    String detail() {
        if (fullyCached()) return "已复用网页缓存";
        String result = "资源加载 " + bytes(loadedBytes) + " / " + bytes(totalBytes);
        if (downloadedBytes != null) result += "\n已确认下载 " + bytes(downloadedBytes) + " · 缓存复用 " + bytes(cachedBytes);
        if (unknownBytes > 0) result += "\n来源待确认 " + bytes(unknownBytes);
        return result + "\n资源 " + completed + " / " + total + " 项";
    }
    private static String bytes(long value) {
        if (value < 1000) return value + " B";
        if (value < 1000000) return String.format(Locale.ROOT, "%.1f KB", value / 1000.0);
        return String.format(Locale.ROOT, "%.2f MB", value / 1000000.0);
    }
}
