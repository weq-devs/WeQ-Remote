package io.github.weqdevs.remote;

final class ReleaseManifest {
    final ReleaseVersion version;
    final String filename, sha256;
    private ReleaseManifest(ReleaseVersion version, String filename, String sha256) {
        this.version = version; this.filename = filename; this.sha256 = sha256;
    }
    static ReleaseManifest parse(String text, String platform) {
        if (text == null || text.length() > 65536 || !("ios".equals(platform) || "android".equals(platform))) return null;
        String suffix = "ios".equals(platform) ? "-ios-arm64-unsigned.ipa" : "-android-arm64.apk";
        ReleaseManifest result = null;
        for (String line : text.split("\\r?\\n")) {
            if (line.trim().isEmpty()) continue;
            String[] fields = line.trim().split("\\s+");
            if (fields.length != 2 || !fields[0].matches("[0-9a-f]{64}")) return null;
            String filename = fields[1];
            if (!filename.startsWith("weq-remote-") || !filename.endsWith(suffix)) continue;
            ReleaseVersion version = ReleaseVersion.parse(filename.substring("weq-remote-".length(), filename.length() - suffix.length()));
            if (version == null || result != null) return null;
            result = new ReleaseManifest(version, filename, fields[0]);
        }
        return result;
    }
}
