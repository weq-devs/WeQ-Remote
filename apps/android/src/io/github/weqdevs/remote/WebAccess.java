package io.github.weqdevs.remote;

import java.net.URI;
import java.util.Locale;

/** 网页 UI 使用的地址规则，不改变网络代理或配对协议。 */
final class WebAccess {
    static boolean sameOrigin(String origin, String value) {
        try {
            URI base = new URI(origin), target = new URI(value);
            return base.getScheme().equalsIgnoreCase(target.getScheme())
                && base.getHost() != null && base.getHost().equalsIgnoreCase(target.getHost())
                && port(base) == port(target) && target.getRawUserInfo() == null;
        } catch (Exception ignored) { return false; }
    }
    private static int port(URI uri) {
        return uri.getPort() != -1 ? uri.getPort() : "https".equalsIgnoreCase(uri.getScheme()) ? 443 : 80;
    }
    static boolean external(String value) {
        try {
            URI uri = new URI(value);
            if (uri.getScheme() == null || uri.getRawUserInfo() != null) return false;
            String scheme = uri.getScheme().toLowerCase(Locale.ROOT);
            if (scheme.equals("http") || scheme.equals("https")) return uri.getHost() != null;
            return scheme.equals("mailto") || scheme.equals("tel") || scheme.equals("tencent") || scheme.equals("mqqapi");
        } catch (Exception ignored) { return false; }
    }
    static String fileName(String value) {
        String name = value == null ? "" : value.replace('\\', '/');
        name = name.substring(name.lastIndexOf('/') + 1).replaceAll("[\\p{Cntrl}:]", "_").trim();
        return name.isEmpty() || name.equals(".") || name.equals("..") ? "download" : name;
    }
}
