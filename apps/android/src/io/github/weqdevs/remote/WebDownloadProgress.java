package io.github.weqdevs.remote;

import java.util.Locale;

final class WebDownloadProgress {
    final int completed, total;
    final long loadedBytes, totalBytes;
    WebDownloadProgress(int completed, int total, long loadedBytes, long totalBytes) {
        if (total <= 0 || total > 4096 || completed < 0 || completed > total || totalBytes <= 0 || totalBytes > (1L << 40)
            || loadedBytes < 0 || loadedBytes > totalBytes || (completed == total) != (loadedBytes == totalBytes))
            throw new IllegalArgumentException("invalid resource progress");
        this.completed = completed; this.total = total; this.loadedBytes = loadedBytes; this.totalBytes = totalBytes;
    }
    float fraction() { return (float) loadedBytes / totalBytes; }
    boolean downloading() { return completed < total; }
    String detail() { return "已加载 " + bytes(loadedBytes) + " / " + bytes(totalBytes) + "\n资源 " + completed + " / " + total + " 项"; }
    private static String bytes(long value) {
        if (value < 1000) return value + " B";
        if (value < 1000000) return String.format(Locale.ROOT, "%.1f KB", value / 1000.0);
        return String.format(Locale.ROOT, "%.2f MB", value / 1000000.0);
    }
}
