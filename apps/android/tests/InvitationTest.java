package io.github.weqdevs.remote;

public final class InvitationTest {
    public static void main(String[] args) throws Exception {
        String secret = new String(new char[64]).replace('\0', 'a');
        String prefix = "weq-remote://pair?v=1&endpoint=";
        String suffix = "&invitation=" + secret;
        Invitation valid = Invitation.parse(prefix + "http%3A%2F%2F100.64.0.1%3A7691" + suffix);
        require(valid.endpoint.equals("http://100.64.0.1:7691"), "valid invitation");
        for (String endpoint : new String[]{"http://127.0.0.1:7691", "http://100.128.0.1:80", "http://example.com:80", "http://user@100.64.0.1:80", "http://100.64.0.1:0", "http://100.64.0.1:80/path"}) {
            reject(prefix + java.net.URLEncoder.encode(endpoint, "UTF-8") + suffix);
        }
        reject(prefix + "http%3A%2F%2F100.64.0.1%3A7691" + suffix + "&v=1");
        reject("https://example.com");
        String authKey = "tskey-auth-" + new String(new char[40]).replace('\0', 'k');
        String bootstrap = (prefix + "http%3A%2F%2F100.64.0.1%3A7691" + suffix).replace("v=1", "v=2") + "&authKey=" + authKey + "&expiresAt=" + (System.currentTimeMillis() + 120000);
        Invitation enrollment = Invitation.parse(bootstrap);
        require(authKey.equals(enrollment.authKey) && enrollment.expiresAt > System.currentTimeMillis(), "v2 enrollment invitation");
        reject(bootstrap.replace(authKey, "tskey-api-invalid"));
        reject(bootstrap.replace("v=2", "v=1"));
        reject(bootstrap + "&authKey=" + authKey);
        reject(bootstrap.replaceAll("expiresAt=[0-9]+", "expiresAt=" + (System.currentTimeMillis() - 1000)));
        reject(bootstrap.replaceAll("expiresAt=[0-9]+", "expiresAt=" + (System.currentTimeMillis() + 3600000)));
        reject(bootstrap.replace("&authKey=" + authKey, "&control=http%3A%2F%2Fevil.invalid"));
        reject(bootstrap.replace(authKey, authKey + "%0A"));
        String direct = "weq-remote://pair?v=3&endpoint=https%3A%2F%2F192.168.1.8%3A7691" + suffix + "&fingerprint=" + secret;
        require(secret.equals(Invitation.parse(direct).fingerprint), "direct pinned TLS invitation");
        reject(direct.replace("https", "http"));
        reject(direct.replace("192.168.1.8", "8.8.8.8"));
        reject(direct.replace("fingerprint=" + secret, "fingerprint=bad"));
        reject(direct + "&fingerprint=" + secret);
        String multi = direct.replace("v=3", "v=4") + "&endpoint=http%3A%2F%2F100.64.0.1%3A7691&endpoint=https%3A%2F%2F100.64.0.1%3A7692";
        require(Invitation.parse(multi).endpoints.size() == 3, "v4 keeps all connection routes");
        String multiKey = multi + "&authKey=" + authKey + "&expiresAt=" + (System.currentTimeMillis() + 120000);
        require(authKey.equals(Invitation.parse(multiKey).authKey), "v4 enrollment");
        reject(multi + "&endpoint=https%3A%2F%2F192.168.1.8%3A7691");
        reject(multi.replace("100.64.0.1", "8.8.8.8"));
        reject(multi.replace("v=4", "v=3"));
        reject(multi + "&unknown=x");
        reject(multiKey.replaceAll("expiresAt=[0-9]+", "expiresAt=1000000000000"));
        String a = Invitation.credential(), b = Invitation.credential();
        require(a.matches("[a-f0-9]{64}") && !a.equals(b), "random credential");
        require(Invitation.hash(a).length() == 64, "credential hash");
        require(Invitation.hash("test").equals("9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"), "desktop hash convention");
        String payload = multiKey;
        com.google.zxing.common.BitMatrix qr = new com.google.zxing.qrcode.QRCodeWriter().encode(payload, com.google.zxing.BarcodeFormat.QR_CODE, 300, 300);
        int[] pixels = new int[90000];
        for (int y = 0; y < 300; y++) for (int x = 0; x < 300; x++) pixels[y * 300 + x] = qr.get(x, y) ? 0xff000000 : 0xffffffff;
        com.google.zxing.BinaryBitmap bitmap = new com.google.zxing.BinaryBitmap(new com.google.zxing.common.HybridBinarizer(new com.google.zxing.RGBLuminanceSource(300, 300, pixels)));
        String decoded = new com.google.zxing.MultiFormatReader().decode(bitmap).getText();
        require(Invitation.parse(decoded).endpoints.size() == 3, "real v4 QR decode");
        if (args.length == 1) {
            java.awt.image.BufferedImage image = javax.imageio.ImageIO.read(new java.io.File(args[0]));
            int[] original = image.getRGB(0, 0, image.getWidth(), image.getHeight(), null, 0, image.getWidth());
            com.google.zxing.BinaryBitmap desktop = new com.google.zxing.BinaryBitmap(new com.google.zxing.common.HybridBinarizer(new com.google.zxing.RGBLuminanceSource(image.getWidth(), image.getHeight(), original)));
            Invitation actual = Invitation.parse(new com.google.zxing.MultiFormatReader().decode(desktop).getText());
            require(actual.multiRoute && actual.endpoints.size() == 8 && actual.authKey != null, "desktop runtime maximum-route QR decode");
        }
        System.out.println("Invitation tests passed: parsing, destination, duplicates, random credential, SHA-256, real QR decode");
    }
    private static void reject(String link) throws Exception { try { Invitation.parse(link); } catch (Exception expected) { return; } throw new AssertionError("unsafe invitation accepted"); }
    private static void require(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
}
