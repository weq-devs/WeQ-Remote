package io.github.weqdevs.remote;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.concurrent.*;

final class UpdateMirrors {
    interface Fetch { byte[] read(String url, boolean range) throws Exception; }
    static final class Candidate {
        final String prefix;
        final ReleaseManifest manifest;
        final long nanos;
        double speed;
        Candidate(String prefix, ReleaseManifest manifest, long nanos) { this.prefix = prefix; this.manifest = manifest; this.nanos = nanos; }
        String label() { try { return prefix.isEmpty() ? "github.com（直连）" : new URL(prefix).getHost(); } catch (Exception ignored) { return prefix; } }
        String downloadURL() { return prefix + "https://github.com/weq-devs/WeQ-Remote/releases/download/v" + manifest.version.text + "/" + manifest.filename; }
    }
    static List<Candidate> resolve(List<String> prefixes) throws Exception {
        return resolve(prefixes, (ReleaseCatalog) null);
    }
    static List<Candidate> resolve(List<String> prefixes, ReleaseCatalog release) throws Exception {
        ConcurrentMap<HttpURLConnection, Boolean> active = new ConcurrentHashMap<>();
        try { return resolve(prefixes, release, (url, range) -> read(url, range, active), () -> {
            for (HttpURLConnection connection : active.keySet()) connection.disconnect();
        }); }
        finally { for (HttpURLConnection connection : active.keySet()) connection.disconnect(); }
    }
    static List<Candidate> resolve(List<String> prefixes, Fetch fetch) throws Exception {
        return resolve(prefixes, null, fetch);
    }
    static List<Candidate> resolve(List<String> prefixes, ReleaseCatalog release, Fetch fetch) throws Exception {
        return resolve(prefixes, release, fetch, () -> {});
    }
    private static List<Candidate> resolve(List<String> prefixes, ReleaseCatalog release, Fetch fetch, Runnable cancelRequests) throws Exception {
        if (prefixes.isEmpty() || prefixes.size() > 64) throw new Exception("invalid mirrors");
        ExecutorService pool = Executors.newFixedThreadPool(Math.min(16, prefixes.size()));
        List<Future<Candidate>> futures = new ArrayList<>();
        try {
            CompletionService<Candidate> completed = new ExecutorCompletionService<>(pool);
            for (String prefix : prefixes) futures.add(completed.submit(() -> {
                long started = System.nanoTime();
                String directory = release == null ? "latest/download" : "download/" + release.tag;
                byte[] data = fetch.read(prefix + "https://github.com/weq-devs/WeQ-Remote/releases/" + directory + "/SHA256SUMS", false);
                ReleaseManifest manifest = ReleaseManifest.parse(new String(data, java.nio.charset.StandardCharsets.UTF_8), "android");
                if (manifest == null) throw new Exception("invalid manifest");
                if (release != null && manifest.version.compareTo(release.version) != 0) throw new Exception("version mismatch");
                return new Candidate(prefix, manifest, System.nanoTime() - started);
            }));
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(8);
            List<Candidate> healthy = new ArrayList<>();
            for (int i = 0; i < futures.size(); i++) {
                long remaining = deadline - System.nanoTime();
                if (remaining <= 0) break;
                Future<Candidate> done = completed.poll(remaining, TimeUnit.NANOSECONDS);
                if (done == null) break;
                try { healthy.add(done.get()); } catch (ExecutionException unavailable) { }
            }
            for (Future<?> future : futures) future.cancel(true);
            cancelRequests.run();
            if (healthy.isEmpty()) throw new Exception("no mirrors");
            ReleaseVersion latest = healthy.stream().map(candidate -> candidate.manifest.version).max(ReleaseVersion::compareTo).get();
            healthy.removeIf(candidate -> candidate.manifest.version.compareTo(latest) != 0);
            healthy.sort(Comparator.comparingLong(candidate -> candidate.nanos));
            List<Future<Double>> speeds = new ArrayList<>();
            for (Candidate candidate : healthy.subList(0, Math.min(3, healthy.size()))) speeds.add(pool.submit(() -> {
                try {
                    long start = System.nanoTime();
                    byte[] data = fetch.read(candidate.downloadURL(), true);
                    double seconds = (System.nanoTime() - start) / 1e9;
                    if (data.length >= 65536 && seconds > 0) return data.length / seconds;
                } catch (Exception unavailable) { }
                return 0.0;
            }));
            long speedDeadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10);
            for (int i = 0; i < speeds.size(); i++) {
                long remaining = speedDeadline - System.nanoTime();
                if (remaining <= 0) break;
                try { healthy.get(i).speed = speeds.get(i).get(remaining, TimeUnit.NANOSECONDS); }
                catch (TimeoutException unavailable) { break; }
            }
            for (Future<?> speed : speeds) speed.cancel(true);
            cancelRequests.run();
            healthy.sort(Comparator.comparingDouble((Candidate candidate) -> -candidate.speed).thenComparingLong(candidate -> candidate.nanos));
            return healthy;
        } finally {
            for (Future<?> future : futures) future.cancel(true);
            pool.shutdownNow();
        }
    }
    static String releaseJSON() throws Exception {
        java.net.HttpURLConnection connection = (java.net.HttpURLConnection) new URL("https://api.github.com/repos/weq-devs/WeQ-Remote/releases?per_page=100").openConnection();
        connection.setConnectTimeout(8000); connection.setReadTimeout(8000);
        connection.setRequestProperty("Accept", "application/vnd.github+json");
        connection.setRequestProperty("User-Agent", "WeQRemote");
        try {
            if (connection.getResponseCode() != 200) throw new Exception("release lookup failed");
            try (InputStream stream = connection.getInputStream()) {
                ByteArrayOutputStream body = new ByteArrayOutputStream();
                byte[] buffer = new byte[8192]; int count;
                while ((count = stream.read(buffer)) != -1) {
                    if (body.size() + count > 4 * 1024 * 1024) throw new Exception("release list too large");
                    body.write(buffer, 0, count);
                }
                return body.toString("UTF-8");
            }
        } finally { connection.disconnect(); }
    }
    private static byte[] read(String url, boolean range, ConcurrentMap<HttpURLConnection, Boolean> active) throws Exception {
        if (Thread.currentThread().isInterrupted()) throw new InterruptedException();
        int limit = range ? 262144 : 65536;
        HttpURLConnection connection = (HttpURLConnection) new URL(url).openConnection();
        active.put(connection, true);
        connection.setConnectTimeout(4000); connection.setReadTimeout(4000);
        connection.setRequestProperty("Cache-Control", "no-cache");
        if (range) connection.setRequestProperty("Range", "bytes=0-" + (limit - 1));
        try {
            int status = connection.getResponseCode();
            if ((status != 200 && status != 206) || !"https".equals(connection.getURL().getProtocol())) throw new Exception("unavailable");
            ByteArrayOutputStream data = new ByteArrayOutputStream();
            try (InputStream stream = connection.getInputStream()) {
                byte[] buffer = new byte[8192];
                long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(6);
                while (data.size() < limit) {
                    if (Thread.currentThread().isInterrupted() || System.nanoTime() > deadline) throw new Exception("timeout");
                    int count = stream.read(buffer, 0, Math.min(buffer.length, limit - data.size()));
                    if (count < 0) return data.toByteArray();
                    data.write(buffer, 0, count);
                }
                if (!range) throw new Exception("manifest too large");
            }
            return data.toByteArray();
        } finally { active.remove(connection); connection.disconnect(); }
    }
}
