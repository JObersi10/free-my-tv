package io.freemytv;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * universal.sh addition: when Config.RANDOM_BACKGROUND is on, a rotating choice of Unsplash photos
 * (unsplash_key in config.properties, a free Access Key from unsplash.com/developers) feeds the same import
 * Photos.java gives tools/photos.py and ImmichPhotos, so they show on the home screen and the screensaver
 * exactly like "My Photos" already does — nothing in HomeView or Screensaver's drawing code changes.
 * Immich, when configured, takes priority over this.
 */
final class RandomPhotos {
    private RandomPhotos() {}

    // Two independent triggers: a short cooldown so opening the home screen fetches something new almost every
    // time (not gated behind a long wait), and a free-running timer that fires on its own every IDLE_MS even if
    // the home screen is just left open and idle — it doesn't wait for a resume event to check back in.
    private static final long CLICK_COOLDOWN_MS = 90_000L;
    private static final long IDLE_MS = 15 * 60_000L;
    private static final long RETRY_MS = 5 * 60_000L;
    private static final int COUNT = 10;
    private static final String PREFIX = "random-";
    private static final String API = "https://api.unsplash.com";

    private static final ExecutorService WORKER = Executors.newSingleThreadExecutor();
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static volatile boolean running;
    private static volatile long lastAttemptAt = 0;
    private static volatile boolean idleTimerStarted;

    static boolean configured() {
        return !Config.UNSPLASH_KEY.trim().isEmpty();
    }

    /** Called once from the home screen's own setup: keeps fetching every IDLE_MS on its own, forever. */
    static void startIdleTimer(Context c) {
        if (idleTimerStarted) return;
        idleTimerStarted = true;
        Context app = c.getApplicationContext();
        Runnable tick = new Runnable() {
            @Override public void run() {
                attempt(app, null);
                MAIN.postDelayed(this, IDLE_MS);
            }
        };
        MAIN.postDelayed(tick, IDLE_MS);
    }

    /** Called every time the home screen opens or resumes: fetches something new unless it just did. */
    static void syncIfDue(Context c, Runnable ready) {
        attempt(c, ready);
    }

    private static void attempt(Context c, Runnable ready) {
        if (!Config.RANDOM_BACKGROUND || !configured() || ImmichPhotos.configured(c) || running) return;
        long now = System.currentTimeMillis();
        if (now - lastAttemptAt < CLICK_COOLDOWN_MS) return;
        lastAttemptAt = now;
        Context app = c.getApplicationContext();
        running = true;
        WORKER.execute(() -> {
            int n = 0;
            try {
                n = sync(app);
                AppLog.w("random background: " + n + " photos, " + Photos.files(app).size() + " in all");
            } catch (Exception e) {
                AppLog.w("random background: " + e.getMessage());
                lastAttemptAt = System.currentTimeMillis() - CLICK_COOLDOWN_MS + RETRY_MS;
            } finally {
                running = false;
            }
            if (n > 0 && ready != null) MAIN.post(ready);
        });
    }

    private static int sync(Context app) throws Exception {
        JSONArray found = new JSONArray(request("/photos/random?count=" + COUNT + "&orientation=landscape&query=nature"));
        File inbox = Photos.privateInbox(app);
        if (!inbox.isDirectory() && !inbox.mkdirs()) return 0;
        int got = 0;
        for (int i = 0; i < found.length(); i++) {
            if (Photos.count(app) >= Photos.MAX) break;
            JSONObject p;
            try {
                p = found.getJSONObject(i);
            } catch (Exception e) {
                continue;
            }
            JSONObject urls = p.optJSONObject("urls");
            String url = urls == null ? null : urls.optString("raw", null);
            if (url == null) continue;
            // Fetched at 2x the final size and at near-max quality, then Photos' own import downsamples it: that
            // clean downsample hides Unsplash's own JPEG compression far better than a 1:1 copy would, which (after
            // Photos' own re-encode on import) visibly softened fine detail like building facades.
            url += (url.contains("?") ? "&" : "?") + "w=" + (Photos.W * 2) + "&h=" + (Photos.H * 2) + "&fit=crop&q=95";
            String credit = credit(p);
            String downloadLocation = downloadLocation(p);
            long seed = System.currentTimeMillis() * 1000 + i;
            File part = new File(inbox, "." + PREFIX + seed), done = new File(inbox, PREFIX + seed + ".jpg");
            try {
                download(url, part);
                if (!part.renameTo(done)) continue;
                File before = Photos.files(app).isEmpty() ? null : Photos.files(app).get(Photos.files(app).size() - 1);
                if (Photos.importWaiting(app) > 0) {
                    got++;
                    // This photo is now in the rotation: this counts as "using" it (guideline 2 — triggering a download).
                    if (downloadLocation != null) ping(downloadLocation);
                    saveCredit(app, before, credit);
                }
            } catch (IOException e) {
                AppLog.w("random background: photo skipped: " + e.getMessage());
            } finally {
                part.delete();
            }
        }
        return got;
    }

    /** "Photo by {name} on Unsplash", from the photographer's own name on their Unsplash profile. */
    private static String credit(JSONObject p) {
        JSONObject user = p.optJSONObject("user");
        String name = user == null ? null : user.optString("name", null);
        JSONObject links = user == null ? null : user.optJSONObject("links");
        String profile = links == null ? null : links.optString("html", null);
        if (name == null || profile == null) return null;
        return name + "\n" + profile + (profile.contains("?") ? "&" : "?") + "utm_source=universal_sh&utm_medium=referral";
    }

    private static String downloadLocation(JSONObject p) {
        JSONObject links = p.optJSONObject("links");
        return links == null ? null : links.optString("download_location", null);
    }

    private static void ping(String url) {
        try {
            request(url.startsWith(API) ? url.substring(API.length()) : url);
        } catch (IOException e) {
            AppLog.w("random background: download ping failed: " + e.getMessage());
        }
    }

    /**
     * Written beside the imported photo Photos.importNow just gave a new name (the newest file that wasn't there a
     * moment ago): Attribution.of reads it back by the photo's own File, after Photos.files() has renamed nothing else
     * since (single worker thread, one photo at a time).
     */
    private static void saveCredit(Context app, File before, String credit) {
        if (credit == null) return;
        java.util.List<File> now = Photos.files(app);
        if (now.isEmpty()) return;
        File imported = now.get(now.size() - 1);
        if (imported.equals(before)) return;   // import didn't actually add a new file
        File sidecar = Attribution.sidecar(imported);
        try (OutputStream out = new FileOutputStream(sidecar)) {
            out.write(credit.getBytes(StandardCharsets.UTF_8));
        } catch (IOException e) {
            AppLog.w("random background: credit not saved: " + e.getMessage());
        }
    }

    private static String request(String path) throws IOException {
        HttpURLConnection http = (HttpURLConnection) new URL(API + path).openConnection();
        http.setConnectTimeout(10_000);
        http.setReadTimeout(30_000);
        http.setRequestProperty("Authorization", "Client-ID " + Config.UNSPLASH_KEY.trim());
        http.setRequestProperty("Accept-Version", "v1");
        try {
            int code = http.getResponseCode();
            if (code != 200) throw new IOException("HTTP " + code);
            try (InputStream in = http.getInputStream()) {
                java.io.ByteArrayOutputStream body = new java.io.ByteArrayOutputStream();
                byte[] buf = new byte[16384];
                for (int n; (n = in.read(buf)) > 0; ) body.write(buf, 0, n);
                return body.toString("UTF-8");
            }
        } finally {
            http.disconnect();
        }
    }

    private static void download(String url, File to) throws IOException {
        HttpURLConnection http = (HttpURLConnection) new URL(url).openConnection();
        http.setConnectTimeout(10_000);
        http.setReadTimeout(30_000);
        http.setInstanceFollowRedirects(true);
        try {
            int code = http.getResponseCode();
            if (code != 200) throw new IOException("HTTP " + code);
            try (InputStream in = http.getInputStream(); OutputStream out = new FileOutputStream(to)) {
                byte[] buf = new byte[65536];
                for (int n; (n = in.read(buf)) > 0; ) out.write(buf, 0, n);
            }
        } finally {
            http.disconnect();
        }
    }

    private static void touch(File f, long when) {
        try {
            if (!f.exists()) new FileOutputStream(f).close();
            f.setLastModified(Math.max(1, when));
        } catch (IOException ignored) {
        }
    }
}
