package io.github.weqdevs.remote;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URLDecoder;
import java.util.Arrays;
import java.util.Base64;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.function.BooleanSupplier;

/** Phone-side HTTPS read, independent of the WebView cookie jar and embedded TS client. */
final class QqImageRequest {
    private static final int LIMIT = 2 * 1024 * 1024;
    private static final List<String> USER_HOSTS = Arrays.asList("thirdqq.qlogo.cn", "q.qlogo.cn", "q1.qlogo.cn", "q2.qlogo.cn");
    private static final List<String> TYPES = Arrays.asList("image/jpeg", "image/png", "image/apng", "image/gif", "image/webp", "image/avif");

    static URI allowed(String raw) {
        if (raw == null || raw.length() > 8192) return null;
        try {
            URI url = URI.create(raw);
            String host = url.getHost();
            if (!"https".equals(url.getScheme()) || url.getPort() != -1 || url.getRawFragment() != null ||
                url.getRawUserInfo() != null || host == null) return null;
            String path = url.getRawPath();
            if (host.equals("tianquan.gtimg.cn") && url.getRawQuery() == null &&
                path.matches("/(?:card|faceAddon)/item/(?!0+/)[0-9a-fA-F]{1,32}/[a-zA-Z0-9_-]+\\.(?:png|apng|jpe?g|gif|webp)")) return url;
            if (host.equals("p.qlogo.cn") && url.getRawQuery() == null &&
                path.matches("/gh/[0-9]{1,20}/[0-9]{1,20}/[0-9]{1,4}")) return url;
            if (url.getRawQuery() == null) return null;
            Map<String, String> fields = new HashMap<>();
            for (String part : url.getRawQuery().split("&", -1)) {
                int equals = part.indexOf('=');
                if (equals <= 0 || equals == part.length() - 1) return null;
                String key = URLDecoder.decode(part.substring(0, equals), "UTF-8");
                String value = URLDecoder.decode(part.substring(equals + 1), "UTF-8");
                if (fields.put(key, value) != null) return null;
            }
            if (USER_HOSTS.contains(host) && path.equals("/g") && fields.size() == 3 &&
                fields.getOrDefault("b", "").matches("qq|sdk") &&
                fields.getOrDefault("nk", "").matches("[0-9]{1,20}") &&
                fields.getOrDefault("s", "").matches("[0-9]{1,4}")) return url;
            if (host.equals("multimedia.nt.qq.com.cn") && path.equals("/download") && fields.size() == 4 &&
                fields.getOrDefault("appid", "").matches("1406|1407") &&
                fields.getOrDefault("spec", "").matches("198|720") &&
                fields.containsKey("fileid") && fields.containsKey("rkey")) return url;
        } catch (IllegalArgumentException | IOException ignored) { }
        return null;
    }

    static String[] fetch(URI url, BooleanSupplier canceled) throws IOException {
        HttpURLConnection request = (HttpURLConnection) url.toURL().openConnection();
        request.setInstanceFollowRedirects(false);
        request.setConnectTimeout(2500);
        request.setReadTimeout(2500);
        request.setUseCaches(false);
        long start = System.nanoTime();
        try {
            if (canceled.getAsBoolean() || request.getResponseCode() != 200) return null;
            String mime = request.getContentType();
            if (mime == null || request.getContentLengthLong() > LIMIT) return null;
            String type = mime.split(";", 2)[0].trim().toLowerCase(Locale.ROOT);
            if (!TYPES.contains(type)) return null;
            try (InputStream input = request.getInputStream(); ByteArrayOutputStream image = new ByteArrayOutputStream()) {
                byte[] buffer = new byte[16384];
                for (int count; (count = input.read(buffer)) != -1;) {
                    if (canceled.getAsBoolean() || System.nanoTime() - start > 5_000_000_000L ||
                        image.size() > LIMIT - count) return null;
                    image.write(buffer, 0, count);
                }
                return image.size() == 0 ? null : new String[]{type, Base64.getEncoder().encodeToString(image.toByteArray())};
            }
        } finally { request.disconnect(); }
    }
}
