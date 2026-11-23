package io.github.weqdevs.remote;

public final class WebDownloadProgressTest {
    public static void main(String[] args) {
        WebDownloadProgress value = new WebDownloadProgress(1, 2, 1000, 10000);
        check(Math.abs(value.fraction() - 0.1f) < 0.0001f);
        check(value.showsRing());
        check(value.downloadedBytes == null && value.detail().equals("资源 1 / 2 项"));
        WebDownloadProgress mixed = new WebDownloadProgress(2, 2, 10000, 10000, 800L, 9000, 0);
        check(mixed.fraction() == 1 && mixed.downloadedBytes == 800 && mixed.cachedBytes == 9000);
        check(mixed.showsRing() && mixed.percentage() == 100);
        check(mixed.detail().equals("资源 2 / 2 项\n已下载 800 B"));
        WebDownloadProgress cached = new WebDownloadProgress(2, 2, 10000, 10000, 0L, 10000, 0);
        check(cached.downloadedBytes == 0 && cached.cachedBytes == 10000);
        check(cached.fullyCached() && !cached.showsRing() && cached.detail().equals("已复用网页缓存"));
        check(!mixed.fullyCached() && !value.fullyCached());
        for (Object bad : new Object[] {0.5, -1, Double.NaN, Double.POSITIVE_INFINITY, true, "1", null}) {
            try { WebDownloadProgress.number(bad); throw new AssertionError("accepted invalid byte count"); }
            catch (IllegalArgumentException expected) { }
        }
        try { new WebDownloadProgress(1, 2, 1, 2, 0L, 1, 1); throw new AssertionError("overlapping source totals"); }
        catch (IllegalArgumentException expected) { }
        check(new WebDownloadProgress(1, 2, 999, 1000).percentage() == 99);
        for (long[] bad : new long[][] {{3,2,1,2}, {2,2,1,2}, {1,2,2,2}, {0,0,0,0}, {1,2,-1,2}, {1,2,1,Long.MAX_VALUE}}) {
            try { new WebDownloadProgress((int)bad[0], (int)bad[1], bad[2], bad[3]); throw new AssertionError("accepted invalid progress"); }
            catch (IllegalArgumentException expected) { }
        }
        WebDownloadProgress.Development development = new WebDownloadProgress.Development(700, 2000000, 698, 1);
        check(development.completed == 700 && development.downloadedBytes == 2000000);
        check(new WebDownloadProgress.Development(1, 0, 0, 1).detail().isEmpty());
        for (long[] bad : new long[][] {{0,1,0,0}, {3,0,2,2}, {3,100,2,1}, {3,-1,0,0}, {Long.MAX_VALUE,0,0,0}}) {
            try { new WebDownloadProgress.Development(bad[0], bad[1], bad[2], bad[3]); throw new AssertionError("accepted invalid development progress"); }
            catch (IllegalArgumentException expected) { }
        }
        System.out.println("WebDownloadProgress tests passed");
    }
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
}
