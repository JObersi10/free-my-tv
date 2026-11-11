package com.gathin.tvhome;

import android.accessibilityservice.AccessibilityService;
import android.content.ActivityNotFoundException;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import android.provider.Settings;
import android.view.accessibility.AccessibilityEvent;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.util.HashMap;
import java.util.Map;

/**
 * Makes this launcher the home screen on Fire OS, which ignores the default-home setting.
 *
 * Fire OS never passes the Home key to accessibility services, so this watches windows instead: when Amazon's
 * home screen comes up, this launcher opens over it straight away. One exception: Amazon's home screen also
 * flashes up on the way into Settings, right after a window from Amazon's settings app, so a home screen that
 * follows a settings window within SETTINGS_GRACE_MS is left alone. Also opens the launcher once at boot.
 *
 * Turned on and off from the launcher (Menu on the Settings button) when the app holds WRITE_SECURE_SETTINGS
 * (granted over adb: pm grant com.gathin.tvhome android.permission.WRITE_SECURE_SETTINGS), or over adb:
 *   settings put secure enabled_accessibility_services com.gathin.tvhome/com.gathin.tvhome.HomeRedirectService
 *   settings put secure accessibility_enabled 1
 */
public class HomeRedirectService extends AccessibilityService {

    private static final String TAG = "HomeRedirect";
    private static final String AMAZON_LAUNCHER = "com.amazon.tv.launcher";
    private static final String AMAZON_HOME = "HomeActivity";
    private static final String[] SETTINGS_APPS = {"com.amazon.tv.settings", "com.amazon.tv.quicksettings"};
    private static final long SETTINGS_GRACE_MS = 2000;     // measured: settings window -> home flash ~200 ms
    private static final long BOOT_WINDOW_MS = 3 * 60_000;  // service connecting this soon after boot = boot

    // Escape hatch: a Fire TV Home shortcut button (FreeMyTV's Shortcuts row) sends this broadcast, which pauses
    // the redirect so Amazon's real home screen stays up for PAUSE_MS instead of instantly bouncing back.
    static final String ACTION_PAUSE = "com.gathin.tvhome.PAUSE_REDIRECT";
    private static final long PAUSE_MS = 45_000;
    private long pausedUntil = 0;

    private final android.content.BroadcastReceiver pauseReceiver = new android.content.BroadcastReceiver() {
        @Override public void onReceive(Context ctx, Intent intent) {
            pausedUntil = SystemClock.uptimeMillis() + PAUSE_MS;
            Log.i(TAG, "redirect paused for " + (PAUSE_MS / 1000) + "s (Fire TV Home shortcut)");
            startActivity(new Intent()
                    .setComponent(new ComponentName(AMAZON_LAUNCHER, "com.amazon.tv.launcher.ui.HomeActivity_vNext"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NO_ANIMATION));
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();
        registerReceiver(pauseReceiver, new android.content.IntentFilter(ACTION_PAUSE),
                Build.VERSION.SDK_INT >= 33 ? Context.RECEIVER_EXPORTED : 0);
    }

    @Override
    public void onDestroy() {
        super.onDestroy();
        try { unregisterReceiver(pauseReceiver); } catch (RuntimeException ignored) { }
    }

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable redirect = this::openLauncher;
    private long settingsSeenAt = -SETTINGS_GRACE_MS;

    @Override
    protected void onServiceConnected() {
        if (SystemClock.elapsedRealtime() < BOOT_WINDOW_MS) openLauncher();
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        if (event.getEventType() != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return;
        CharSequence pkg = event.getPackageName(), cls = event.getClassName();
        if (pkg == null || cls == null) return;
        long now = SystemClock.uptimeMillis();
        for (String app : SETTINGS_APPS) if (pkg.toString().startsWith(app)) settingsSeenAt = now;
        handler.removeCallbacks(redirect);
        if (!AMAZON_LAUNCHER.contentEquals(pkg) || !cls.toString().contains(AMAZON_HOME)) {
            checkButtonRedirect(pkg.toString());
            return;
        }
        if (now - settingsSeenAt < SETTINGS_GRACE_MS) {
            Log.i(TAG, "home screen on the way into Settings: left alone");
            return;
        }
        if (now < pausedUntil) {
            Log.i(TAG, "redirect paused (Fire TV Home shortcut): leaving Amazon's home up");
            return;
        }
        Log.i(TAG, "home screen: opening launcher");
        handler.post(redirect);
    }

    // ---- quick-app-button redirect (Prime Video / Disney+ / Peacock / etc.) ---------------------
    //
    // Fire OS's quick-app remote buttons (Netflix/Prime/Disney+/...) never reach onKeyEvent, even with
    // canRequestFilterKeyEvents (confirmed live: Key Mapper's own trigger recorder saw nothing when pressed,
    // same as the Home key below). So this can't block the press itself - instead, same trick as the Home
    // redirect: let the button do what it already does (launch the real app), watch for that app's window
    // appearing, and immediately jump elsewhere before the user settles on it. There's an unavoidable brief
    // flash of the original app (same as the Home-screen flash above) and this fires the same way whether the
    // app was opened by its remote button or by its icon on the home screen - Fire OS gives no event data
    // to tell those apart, so this affects the whole app, not just its dedicated button.
    //
    // Configured over adb, no app UI, no rebuild needed. One mapping per line in a plain text file at
    // getExternalFilesDir()/button_redirects.txt (push with adb, e.g.
    //   adb push button_redirects.txt /sdcard/Android/data/com.gathin.tvhome/files/button_redirects.txt
    // ), each line "source.package=target.package" or "source.package=OFF" (OFF bounces back to this
    // launcher, same as pressing Home). Blank lines and lines starting with # are ignored. Re-read whenever
    // its mtime changes, so no restart is needed after pushing a new version.
    private final Map<String, String> buttonRedirects = new HashMap<>();
    private long buttonRedirectsMtime = -1;

    private void loadButtonRedirectsIfChanged() {
        File f = new File(getExternalFilesDir(null), "button_redirects.txt");
        long mtime = f.lastModified();
        if (mtime == buttonRedirectsMtime) return;
        buttonRedirectsMtime = mtime;
        buttonRedirects.clear();
        if (mtime == 0) return; // file doesn't exist
        try (BufferedReader r = new BufferedReader(new FileReader(f))) {
            String line;
            while ((line = r.readLine()) != null) {
                line = line.trim();
                if (line.isEmpty() || line.startsWith("#")) continue;
                int eq = line.indexOf('=');
                if (eq <= 0) continue;
                buttonRedirects.put(line.substring(0, eq).trim(), line.substring(eq + 1).trim());
            }
            Log.i(TAG, "button_redirects.txt: " + buttonRedirects.size() + " mapping(s) loaded");
        } catch (Exception e) {
            Log.w(TAG, "button_redirects.txt: couldn't read it (" + e + ")");
        }
    }

    private void checkButtonRedirect(String pkg) {
        loadButtonRedirectsIfChanged();
        String target = buttonRedirects.get(pkg);
        if (target == null) return;
        if ("OFF".equals(target)) {
            Log.i(TAG, pkg + " opened: bouncing back (configured OFF)");
            openLauncher();
            return;
        }
        Log.i(TAG, pkg + " opened: redirecting to " + target);
        Intent launch = getPackageManager().getLaunchIntentForPackage(target);
        if (launch == null) {
            Log.w(TAG, target + " has no launch intent (not installed?) - bouncing back instead");
            openLauncher();
            return;
        }
        try {
            startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NO_ANIMATION));
        } catch (ActivityNotFoundException | SecurityException e) {
            Log.w(TAG, "couldn't start " + target + " (" + e + ") - bouncing back instead");
            openLauncher();
        }
    }

    @Override
    public void onInterrupt() {
    }

    // universal.sh patch: redirect to FreeMyTV's Fire TV home screen instead of this launcher's own
    // MainActivity, falling back to MainActivity only if FreeMyTV isn't installed (or gets removed later).
    // FreeMyTV's Fire-TV-safe entry point (.FireHomeActivity) is exported="false" in its own manifest,
    // so another app can never start it (SecurityException, not an accessibility restriction) — only
    // .HomeActivity is exported. It's the same home-screen content; FreeMyTV only built FireHomeActivity
    // as a focus-safer variant for when IT opens itself, which doesn't apply to us calling in from outside.
    private static final String REDIRECT_PACKAGE = "io.freemytv";
    private static final String REDIRECT_ACTIVITY = "io.freemytv.HomeActivity";

    private void openLauncher() {
        try {
            startActivity(new Intent()
                    .setComponent(new ComponentName(REDIRECT_PACKAGE, REDIRECT_ACTIVITY))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NO_ANIMATION));
        } catch (ActivityNotFoundException | SecurityException e) {
            Log.w(TAG, "could not open " + REDIRECT_PACKAGE + " (" + e + "), falling back to this launcher's own screen");
            startActivity(new Intent(this, MainActivity.class)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NO_ANIMATION));
        }
    }

    // ---- on/off from the launcher's UI -----------------------------------------------------------

    static boolean isEnabled(Context ctx) {
        String on = Settings.Secure.getString(ctx.getContentResolver(), Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES);
        return on != null && on.contains(component(ctx).flattenToString());
    }

    /** False when the app lacks WRITE_SECURE_SETTINGS. */
    static boolean setEnabled(Context ctx, boolean on) {
        try {
            Settings.Secure.putString(ctx.getContentResolver(), Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
                    on ? component(ctx).flattenToString() : "");
            Settings.Secure.putInt(ctx.getContentResolver(), Settings.Secure.ACCESSIBILITY_ENABLED, on ? 1 : 0);
            return true;
        } catch (SecurityException e) {
            return false;
        }
    }

    private static ComponentName component(Context ctx) {
        return new ComponentName(ctx, HomeRedirectService.class);
    }
}
