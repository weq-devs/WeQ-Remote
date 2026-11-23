package io.github.weqdevs.remote;

import android.content.Context;
import android.util.AtomicFile;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.function.Consumer;
import org.json.JSONArray;
import org.json.JSONObject;

final class RemoteInstantStore {
    static final int MAX_BYTES = 256 * 1024;
    private static final ExecutorService disk = Executors.newSingleThreadExecutor();

    static final class Row {
        final String id, text;
        final boolean mine;
        Row(String id, String text, boolean mine) { this.id = id; this.text = text; this.mine = mine; }
    }
    static final class Chat {
        final String id, title;
        final List<Row> rows;
        Chat(String id, String title, List<Row> rows) { this.id = id; this.title = title; this.rows = rows; }
    }
    static final class Snapshot {
        final String scope;
        final List<Chat> chats;
        Snapshot(String scope, List<Chat> chats) { this.scope = scope; this.chats = chats; }
    }

    static Snapshot decode(String text, long now) {
        try {
            if (text == null || text.length() > MAX_BYTES || text.getBytes(StandardCharsets.UTF_8).length > MAX_BYTES) return null;
            JSONObject root = new JSONObject(text);
            if (!root.has("scope")) return null;
            String scope = root.isNull("scope") ? null : field(root, "scope", 512);
            JSONArray entries = root.has("chats") ? root.getJSONArray("chats") : null;
            if (entries == null) return new Snapshot(scope, null);
            if (entries.length() > 6) return null;
            List<Chat> chats = new ArrayList<>();
            HashSet<String> ids = new HashSet<>();
            for (int i = 0; i < entries.length(); i++) {
                JSONObject entry = entries.getJSONObject(i);
                String id = field(entry, "id", 240), title = field(entry, "title", 480);
                Object expiry = entry.get("expiresAt");
                if (!(expiry instanceof Number) || !ids.add(id)) return null;
                double expiresAt = ((Number)expiry).doubleValue();
                if (!Double.isFinite(expiresAt)) return null;
                JSONArray content = entry.getJSONArray("rows");
                if (content.length() == 0 || content.length() > 24) return null;
                List<Row> rows = new ArrayList<>();
                HashSet<String> rowIds = new HashSet<>();
                for (int j = 0; j < content.length(); j++) {
                    JSONObject row = content.getJSONObject(j);
                    String rowId = field(row, "id", 240);
                    Object mine = row.get("mine");
                    if (!(mine instanceof Boolean) || !rowIds.add(rowId)) return null;
                    rows.add(new Row(rowId, field(row, "text", 1440), (Boolean)mine));
                }
                if (scope != null && expiresAt > now && expiresAt <= now + 86_460_000) chats.add(new Chat(id, title, rows));
            }
            return new Snapshot(scope, chats);
        } catch (org.json.JSONException | IllegalArgumentException badFormat) { return null; }
    }

    private static String field(JSONObject object, String key, int limit) throws org.json.JSONException {
        Object value = object.get(key);
        if (!(value instanceof String) || ((String)value).isEmpty() || ((String)value).getBytes(StandardCharsets.UTF_8).length > limit)
            throw new org.json.JSONException("Invalid field");
        return (String)value;
    }
    private static AtomicFile file(Context context, String token) {
        try { return new AtomicFile(new File(new File(context.getCacheDir(), "instant-v1"), Invitation.hash(token))); }
        catch (Exception unavailable) { throw new IllegalStateException(unavailable); }
    }
    private static String read(AtomicFile file) {
        try (java.io.FileInputStream input = file.openRead()) {
            long size = input.getChannel().size();
            if (size <= 0 || size > MAX_BYTES) return null;
            byte[] data = new byte[(int)size];
            new java.io.DataInputStream(input).readFully(data);
            return new String(data, StandardCharsets.UTF_8);
        } catch (java.io.IOException ignored) { return null; }
    }
    static void load(Context context, String token, Consumer<Snapshot> complete) {
        disk.execute(() -> complete.accept(decode(read(file(context, token)), System.currentTimeMillis())));
    }
    static void update(Context context, String token, String payload) {
        disk.execute(() -> {
            long now = System.currentTimeMillis();
            Snapshot update = decode(payload, now);
            if (update == null) return;
            AtomicFile target = file(context, token);
            String previous = read(target);
            if (update.chats == null && update.scope != null) {
                Snapshot old = decode(previous, now);
                if (old != null && update.scope.equals(old.scope)) return;
            }
            if (update.scope == null || update.chats == null || update.chats.isEmpty()) { target.delete(); return; }
            if (payload.equals(previous)) return;
            FileOutputStream stream = null;
            try {
                stream = target.startWrite();
                stream.write(payload.getBytes(StandardCharsets.UTF_8));
                target.finishWrite(stream);
            } catch (java.io.IOException failure) { if (stream != null) target.failWrite(stream); }
        });
    }
    static void clear(Context context, String token) { disk.execute(() -> file(context, token).delete()); }
}
