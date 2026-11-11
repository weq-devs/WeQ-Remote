package io.github.weqdevs.remote;

public final class ReleaseVersionTest {
    public static void main(String[] args) {
        String[] ordered = {"0.2.0", "1.0.0b2", "1.0.0b10", "1.0.0", "1.0.1b1", "1.10.0", "2.0.0"};
        for (int i = 1; i < ordered.length; i++) check(ReleaseVersion.parse(ordered[i - 1]).compareTo(ReleaseVersion.parse(ordered[i])) < 0);
        for (String invalid : new String[]{"1.0", "v1.0.0", "01.0.0", "1.0.0b0", "1.0.0\n", "1.0.0-rc.1", "999999999999999999999.0.0"}) check(ReleaseVersion.parse(invalid) == null);
        String line = new String(new char[64]).replace('\0', 'a') + "  weq-remote-1.0.0b10-android-arm64.apk\n";
        check("1.0.0b10".equals(ReleaseManifest.parse(line, "android").version.text));
        check(ReleaseManifest.parse(line, "ios") == null);
        check(ReleaseManifest.parse(line + line, "android") == null);
        check(ReleaseManifest.parse("<html>blocked</html>", "android") == null);
        check(ReleaseManifest.parse(line.replace("1.0.0b10", "../../bad"), "android") == null);
    }
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
}
