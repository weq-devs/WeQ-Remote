package io.github.weqdevs.remote;

public final class WebResourceProgressTest {
    public static void main(String[] args) {
        WebResourceProgress value = new WebResourceProgress(1, 2);
        check(value.detail().equals("网页资源已就绪 1 / 2 项"));
        check(value.stage().equals(WebResourceProgress.PREPARING_MESSAGE));
        WebResourceProgress complete = new WebResourceProgress(2, 2);
        check(complete.detail().equals("网页资源已就绪 2 / 2 项"));
        check(complete.stage().equals("正在初始化网页"));
        check(new WebResourceProgress(0, 4096).total == 4096);
        check(WebResourceProgress.count(1.0) == 1);
        for (int[] bad : new int[][] {{3,2}, {-1,2}, {0,0}, {0,4097}}) {
            try { new WebResourceProgress(bad[0], bad[1]); throw new AssertionError("accepted invalid progress"); }
            catch (IllegalArgumentException expected) { }
        }
        for (Object bad : new Object[] {0.5, -1, 4097, Double.POSITIVE_INFINITY, Double.NaN, true, "1", null}) {
            try { WebResourceProgress.count(bad); throw new AssertionError("accepted invalid count"); }
            catch (IllegalArgumentException expected) { }
        }
        System.out.println("WebResourceProgress tests passed");
    }
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
}
