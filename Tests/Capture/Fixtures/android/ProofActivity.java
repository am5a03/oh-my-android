package dev.mobilecapture.proof;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;
import android.widget.TextView;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

/** Neutral, debuggable fixture. It logs and POSTs only an operator-supplied proof nonce. */
public final class ProofActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        final TextView text = new TextView(this);
        text.setPadding(30, 60, 30, 30);
        text.setText("Mobile capture proof\nPreparing a neutral HTTPS POST…");
        setContentView(text);
        final String nonce = value("proof_nonce", "proof-" + System.currentTimeMillis());
        final String endpoint = value("proof_url", "https://httpbingo.org/anything");
        new Thread(() -> {
            Log.i("CaptureProof", "proof-start nonce=" + nonce);
            Log.v("CaptureProof", "proof-verbose nonce=" + nonce);
            Log.d("CaptureProof", "proof-debug nonce=" + nonce + " Unicode=café 東京 🚀");
            Log.i("CaptureProof", "proof-info nonce=" + nonce);
            HttpURLConnection connection = null;
            try {
                String safe = nonce.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n");
                byte[] body = ("{\"capture_proof\":\"" + safe + "\",\"platform\":\"android\"}")
                    .getBytes(StandardCharsets.UTF_8);
                connection = (HttpURLConnection) new URL(endpoint).openConnection();
                connection.setConnectTimeout(20000);
                connection.setReadTimeout(20000);
                connection.setRequestMethod("POST");
                connection.setRequestProperty("Content-Type", "application/json");
                connection.setDoOutput(true);
                connection.getOutputStream().write(body);
                connection.getOutputStream().close();
                int status = connection.getResponseCode();
                InputStream stream = status < 400 ? connection.getInputStream() : connection.getErrorStream();
                ByteArrayOutputStream received = new ByteArrayOutputStream();
                byte[] buffer = new byte[4096];
                int count;
                while (stream != null && (count = stream.read(buffer)) != -1) received.write(buffer, 0, count);
                if (stream != null) stream.close();
                StringBuilder digest = new StringBuilder();
                for (byte part : MessageDigest.getInstance("SHA-256").digest(received.toByteArray())) {
                    digest.append(String.format("%02x", part & 255));
                }
                final String result = "proof-response nonce=" + nonce + " status=" + status
                    + " bytes=" + received.size() + " sha256=" + digest;
                Log.i("CaptureProof", result);
                runOnUiThread(() -> text.setText("Mobile capture proof\n" + result));
            } catch (Exception error) {
                final String result = "proof-error nonce=" + nonce + " " + error;
                Log.e("CaptureProof", result);
                runOnUiThread(() -> text.setText(result));
            } finally {
                if (connection != null) connection.disconnect();
            }
        }, "capture-proof").start();
    }

    private String value(String name, String fallback) {
        String result = getIntent().getStringExtra(name);
        return result == null || result.isEmpty() ? fallback : result;
    }
}
