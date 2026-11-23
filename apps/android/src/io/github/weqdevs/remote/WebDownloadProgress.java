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
    int percentage() { return completed == total ? 100 : Math.min(99, Math.round(fraction() * 100)); }
    boolean fullyCached() { return completed == total && downloadedBytes != null && downloadedBytes == 0 && cachedBytes == totalBytes && unknownBytes == 0; }
    boolean showsRing() { return !fullyCached(); }
    String detail() {
        if (fullyCached()) return "已复用网页缓存";
        String result = "资源 " + completed + " / " + total + " 项";
        return downloadedBytes != null && downloadedBytes > 0 ? result + "\n已下载 " + bytes(downloadedBytes) : result;
    }
    private static String bytes(long value) {
        if (value < 1000) return value + " B";
        if (value < 1000000) return String.format(Locale.ROOT, "%.1f KB", value / 1000.0);
        return String.format(Locale.ROOT, "%.2f MB", value / 1000000.0);
    }

    static final class Development {
        final int completed, cached, unknown;
        final long downloadedBytes;

        Development(long completed, long downloadedBytes, long cached, long unknown) {
            if (completed < 0 || completed > Integer.MAX_VALUE || cached < 0 || cached > completed
                || unknown < 0 || unknown > completed - cached || downloadedBytes < 0 || downloadedBytes > (1L << 40)
                || (downloadedBytes > 0 && cached + unknown == completed))
                throw new IllegalArgumentException("invalid development resource progress");
            this.completed = (int) completed; this.downloadedBytes = downloadedBytes; this.cached = (int) cached; this.unknown = (int) unknown;
        }

        String detail() {
            String download = downloadedBytes > 0 ? "已下载 " + bytes(downloadedBytes) : "";
            if (cached == 0) return download;
            return (download.isEmpty() ? "" : download + "\n") + "缓存复用 " + cached + " 项";
        }
    }
}
