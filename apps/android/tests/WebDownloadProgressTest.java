package io.github.weqdevs.remote;

public final class WebDownloadProgressTest {
    public static void main(String[] args) {
        WebDownloadProgress value = new WebDownloadProgress(1, 2, 1000, 10000);
        check(Math.abs(value.fraction() - 0.1f) < 0.0001f);
        check(value.downloading());
        check(value.detail().contains("1.0 KB / 10.0 KB"));
        check(value.downloadedBytes == null && value.detail().contains("来源待确认"));
        WebDownloadProgress mixed = new WebDownloadProgress(2, 2, 10000, 10000, 800L, 9000, 0);
        check(mixed.fraction() == 1 && mixed.downloadedBytes == 800 && mixed.cachedBytes == 9000);
        check(mixed.detail().contains("已确认下载") && mixed.detail().contains("缓存复用") && !mixed.detail().contains("来源待确认"));
        check(mixed.stage().equals("正在初始化网页"));
        WebDownloadProgress cached = new WebDownloadProgress(2, 2, 10000, 10000, 0L, 10000, 0);
        check(cached.downloadedBytes == 0 && cached.cachedBytes == 10000);
        check(cached.fullyCached() && cached.detail().equals("已复用网页缓存"));
        check(!mixed.fullyCached() && !value.fullyCached());
        for (Object bad : new Object[] {0.5, -1, Double.NaN, Double.POSITIVE_INFINITY, true, "1", null}) {
            try { WebDownloadProgress.number(bad); throw new AssertionError("accepted invalid byte count"); }
            catch (IllegalArgumentException expected) { }
        }
        try { new WebDownloadProgress(1, 2, 1, 2, 0L, 1, 1); throw new AssertionError("overlapping source totals"); }
        catch (IllegalArgumentException expected) { }
        check(!new WebDownloadProgress(2, 2, 10000, 10000).downloading());
        for (long[] bad : new long[][] {{3,2,1,2}, {2,2,1,2}, {1,2,2,2}, {0,0,0,0}, {1,2,-1,2}, {1,2,1,Long.MAX_VALUE}}) {
            try { new WebDownloadProgress((int)bad[0], (int)bad[1], bad[2], bad[3]); throw new AssertionError("accepted invalid progress"); }
            catch (IllegalArgumentException expected) { }
        }
        System.out.println("WebDownloadProgress tests passed");
    }
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
}
