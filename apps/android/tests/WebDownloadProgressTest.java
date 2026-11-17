package io.github.weqdevs.remote;

public final class WebDownloadProgressTest {
    public static void main(String[] args) {
        WebDownloadProgress value = new WebDownloadProgress(1, 2, 1000, 10000);
        check(Math.abs(value.fraction() - 0.1f) < 0.0001f);
        check(value.downloading());
        check(value.detail().contains("1.0 KB / 10.0 KB"));
        check(!new WebDownloadProgress(2, 2, 10000, 10000).downloading());
        for (long[] bad : new long[][] {{3,2,1,2}, {2,2,1,2}, {1,2,2,2}, {0,0,0,0}, {1,2,-1,2}, {1,2,1,Long.MAX_VALUE}}) {
            try { new WebDownloadProgress((int)bad[0], (int)bad[1], bad[2], bad[3]); throw new AssertionError("accepted invalid progress"); }
            catch (IllegalArgumentException expected) { }
        }
        System.out.println("WebDownloadProgress tests passed");
    }
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
}
