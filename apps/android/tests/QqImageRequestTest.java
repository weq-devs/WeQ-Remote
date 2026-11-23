package io.github.weqdevs.remote;

public final class QqImageRequestTest {
    public static void main(String[] args) {
        String thumb = "https://multimedia.nt.qq.com.cn/download?appid=1406&fileid=fixture&spec=198&rkey=fixture";
        allowed(true, thumb);
        allowed(true, "https://thirdqq.qlogo.cn/g?b=sdk&s=100&nk=123");
        allowed(true, "https://p.qlogo.cn/gh/123/123/100");
        allowed(false, thumb + "&spec=198");
        allowed(false, thumb + "&cookie=fixture");
        allowed(false, thumb.replace("spec=198", "spec=0"));
        allowed(false, thumb.replace("qq.com.cn/", "qq.com.cn.example/"));
        allowed(false, thumb.replace("https:", "http:"));
        allowed(false, "https://x@p.qlogo.cn/gh/123/123/100");
        allowed(false, "https://q.qlogo.cn/g?b=qq&s=100&ek=123");
    }

    private static void allowed(boolean expected, String url) {
        if ((QqImageRequest.allowed(url) != null) != expected) throw new AssertionError(url);
    }
}
