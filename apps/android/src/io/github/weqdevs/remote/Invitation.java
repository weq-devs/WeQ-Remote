package io.github.weqdevs.remote;

import java.net.URI;
import java.net.URLDecoder;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.HashMap;
import java.util.Map;
import java.util.ArrayList;
import java.util.List;
import java.util.HashSet;

final class Invitation {
    final String endpoint;
    final List<String> endpoints;
    final String secret;
    final String authKey;
    final long expiresAt;
    final String fingerprint;
    final boolean multiRoute;
    private Invitation(List<String> endpoints, String secret, String authKey, long expiresAt, String fingerprint, boolean multiRoute) { this.endpoints = java.util.Collections.unmodifiableList(new ArrayList<>(endpoints)); this.endpoint = endpoints.get(0); this.secret = secret; this.authKey = authKey; this.expiresAt = expiresAt; this.fingerprint = fingerprint; this.multiRoute = multiRoute; }

    static Invitation parse(String text) throws Exception {
        if (text == null || text.length() > 2048) throw new IllegalArgumentException("配对链接无效");
        URI uri = new URI(text.trim());
        if (!"weq-remote".equals(uri.getScheme()) || !"pair".equals(uri.getHost()) || uri.getUserInfo() != null || uri.getPort() != -1 || !"".equals(uri.getPath()) || uri.getFragment() != null || uri.getRawQuery() == null) throw new IllegalArgumentException("配对链接无效");
        Map<String, String> fields = new HashMap<>();
        List<String> endpoints = new ArrayList<>();
        for (String field : uri.getRawQuery().split("&", -1)) {
            String[] pair = field.split("=", 2);
            if (pair.length != 2) throw new IllegalArgumentException("配对字段无效");
            String key = URLDecoder.decode(pair[0], "UTF-8");
            String value = URLDecoder.decode(pair[1], "UTF-8");
            if ("endpoint".equals(key)) { endpoints.add(value); fields.putIfAbsent(key, value); }
            else if (fields.put(key, value) != null) throw new IllegalArgumentException("配对字段重复");
        }
        boolean multi = "4".equals(fields.get("v"));
        boolean bootstrap = "2".equals(fields.get("v")) || (multi && fields.containsKey("authKey"));
        boolean direct = "3".equals(fields.get("v")) || multi;
        if ((!bootstrap && !direct && !"1".equals(fields.get("v"))) || fields.size() != (multi ? bootstrap ? 6 : 4 : bootstrap ? 5 : direct ? 4 : 3) || !fields.containsKey("endpoint") || !fields.containsKey("invitation") || endpoints.isEmpty() || endpoints.size() > (multi ? 8 : 1) || new HashSet<>(endpoints).size() != endpoints.size()) throw new IllegalArgumentException("配对版本不兼容");
        String fingerprint = direct ? fields.get("fingerprint") : null;
        if (direct && (fingerprint == null || !fingerprint.matches("[a-f0-9]{64}"))) throw new IllegalArgumentException("电脑指纹无效");
        String authKey = null; long expiresAt = 0;
        if (bootstrap) {
            authKey = fields.get("authKey");
            String expiry = fields.get("expiresAt");
            if (authKey == null || !authKey.matches("tskey-auth-[A-Za-z0-9_-]{20,200}") || expiry == null || !expiry.matches("[0-9]{13}")) throw new IllegalArgumentException("入网邀请无效");
            expiresAt = Long.parseLong(expiry);
            if (expiresAt <= System.currentTimeMillis() || expiresAt > System.currentTimeMillis() + 180000) throw new IllegalArgumentException("入网邀请已过期或手机时间不正确，请重新生成");
        }
        for (String address : endpoints) validateEndpoint(address, multi ? address.startsWith("https:") : direct);
        if (multi && bootstrap && endpoints.stream().noneMatch(address -> address.startsWith("http:"))) throw new IllegalArgumentException("缺少内嵌网络地址");
        String secret = fields.get("invitation");
        if (!secret.matches("[a-f0-9]{64}")) throw new IllegalArgumentException("邀请无效");
        return new Invitation(endpoints, secret, authKey, expiresAt, fingerprint, multi);
    }

    static void validateEndpoint(String address, boolean direct) throws Exception {
        URI endpoint = new URI(address);
        String host = endpoint.getHost();
        if (!(direct ? "https" : "http").equals(endpoint.getScheme()) || endpoint.getUserInfo() != null || endpoint.getPort() < 1 || endpoint.getPort() > 65535 || !"".equals(endpoint.getPath()) || endpoint.getRawQuery() != null || endpoint.getFragment() != null || host == null) throw new IllegalArgumentException("电脑地址无效");
        String[] parts = host.split("\\.", -1);
        if (parts.length != 4) throw new IllegalArgumentException("只允许 TS 网络地址");
        int[] octets = new int[4];
        for (int i = 0; i < 4; i++) {
            octets[i] = Integer.parseInt(parts[i]);
            if (!Integer.toString(octets[i]).equals(parts[i]) || octets[i] < 0 || octets[i] > 255) throw new IllegalArgumentException("电脑地址无效");
        }
        boolean tailnet = octets[0] == 100 && octets[1] >= 64 && octets[1] <= 127;
        boolean lan = octets[0] == 10 || (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) || (octets[0] == 192 && octets[1] == 168);
        if (!tailnet && !(direct && lan)) throw new IllegalArgumentException("只允许局域网或 TS 网络地址");
    }

    static String credential() { byte[] bytes = new byte[32]; new SecureRandom().nextBytes(bytes); return hex(bytes); }
    static String hash(String token) throws Exception { return hex(MessageDigest.getInstance("SHA-256").digest(token.getBytes("UTF-8"))); }
    private static String hex(byte[] bytes) { StringBuilder text = new StringBuilder(); for (byte b : bytes) text.append(String.format(java.util.Locale.ROOT, "%02x", b & 255)); return text.toString(); }
}
