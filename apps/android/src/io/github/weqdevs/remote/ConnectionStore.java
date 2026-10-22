package io.github.weqdevs.remote;

import android.content.Context;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import java.security.KeyStore;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import org.json.JSONObject;

// 凭据只以 Keystore 密钥加密后落盘，禁止备份；不保存二维码和 Auth Key。
final class ConnectionStore {
    private static final String ALIAS = "weq-remote-computer";
    private static SecretKey key() throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore"); store.load(null);
        if (store.containsAlias(ALIAS)) return (SecretKey)store.getKey(ALIAS, null);
        KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
        return generator.generateKey();
    }
    static void save(Context context, String endpoint, String token, String fingerprint) throws Exception {
        JSONObject data = new JSONObject().put("endpoint", endpoint).put("token", token).put("fingerprint", fingerprint);
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, key());
        String value = Base64.encodeToString(cipher.getIV(), Base64.NO_WRAP) + ":" + Base64.encodeToString(cipher.doFinal(data.toString().getBytes("UTF-8")), Base64.NO_WRAP);
        if (!context.getSharedPreferences("connection", Context.MODE_PRIVATE).edit().putString("computer", value).commit()) throw new Exception("无法保存电脑凭据");
    }
    static JSONObject load(Context context) throws Exception {
        String value = context.getSharedPreferences("connection", Context.MODE_PRIVATE).getString("computer", null);
        if (value == null) return null;
        String[] parts = value.split(":", -1);
        if (parts.length != 2) throw new Exception("电脑凭据损坏");
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)));
        return new JSONObject(new String(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)), "UTF-8"));
    }
    static void delete(Context context) { context.getSharedPreferences("connection", Context.MODE_PRIVATE).edit().remove("computer").commit(); }
}
