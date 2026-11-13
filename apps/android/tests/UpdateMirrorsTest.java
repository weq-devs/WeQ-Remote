package io.github.weqdevs.remote;

import java.util.Arrays;
import java.util.List;
import java.nio.charset.StandardCharsets;

public final class UpdateMirrorsTest {
    public static void main(String[] args) throws Exception {
        List<ReleaseCatalog.Entry> releases = Arrays.asList(
            new ReleaseCatalog.Entry("v1.0.0b2", false, false, true, true),
            new ReleaseCatalog.Entry("v0.2.0", false, false, true, true),
            new ReleaseCatalog.Entry("v2.0.0", true, false, true, true),
            new ReleaseCatalog.Entry("v3.0.0", false, false, false, true),
            new ReleaseCatalog.Entry("v1.1.0", false, true, true, true));
        if (!"0.2.0".equals(ReleaseCatalog.select(releases, false).version.text)) throw new AssertionError();
        if (!"1.1.0".equals(ReleaseCatalog.select(releases, true).version.text)) throw new AssertionError();
        List<UpdateMirrors.Candidate> ranked = UpdateMirrors.resolve(Arrays.asList("https://old.invalid/", "https://slow.invalid/", "https://fast.invalid/", "https://dead.invalid/"), (url, range) -> {
            if (url.startsWith("https://dead.invalid")) throw new Exception();
            if (range) { Thread.sleep(url.startsWith("https://slow.invalid") ? 100 : 10); return new byte[262144]; }
            String version = url.startsWith("https://old.invalid") ? "0.2.0" : "1.0.0b2";
            return (new String(new char[64]).replace('\0', 'a') + "  weq-remote-" + version + "-android-arm64.apk\n").getBytes(StandardCharsets.UTF_8);
        });
        if (ranked.size() != 2 || !ranked.get(0).prefix.equals("https://fast.invalid/") || !ranked.get(0).downloadURL().contains("/download/v1.0.0b2/")) throw new AssertionError();
        ranked = UpdateMirrors.resolve(Arrays.asList(""), (url, range) -> {
            if (range) throw new Exception("range unavailable");
            return (new String(new char[64]).replace('\0', 'a') + "  weq-remote-1.0.0-android-arm64.apk\n").getBytes(StandardCharsets.UTF_8);
        });
        if (ranked.size() != 1) throw new AssertionError("latency fallback lost");
        ranked = UpdateMirrors.resolve(Arrays.asList(""), null, (url, range) -> {
            if (range) throw new AssertionError("data saver must not sample installers");
            return (new String(new char[64]).replace('\0', 'a') + "  weq-remote-1.0.0-android-arm64.apk\n").getBytes(StandardCharsets.UTF_8);
        }, false);
        if (ranked.size() != 1) throw new AssertionError("data saver lost available mirror");
        try {
            UpdateMirrors.resolve(Arrays.asList(""), (url, range) -> { throw new Exception(); });
            throw new AssertionError("all failed must not become up-to-date");
        } catch (Exception expected) { }
        System.out.println("Update mirror tests passed");
    }
}
