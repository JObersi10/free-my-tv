package com.gathin.tvhome;

import android.accessibilityservice.AccessibilityService;
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
import java.io.InputStreamReader;
import java.util.HashMap;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

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
    private static final String AMAZON_APPSTORE = "com.amazon.venezia";
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
        stopKeyWatcher();
    }

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable redirect = this::openLauncher;
    private long settingsSeenAt = -SETTINGS_GRACE_MS;

    @Override
    protected void onServiceConnected() {
        if (SystemClock.elapsedRealtime() < BOOT_WINDOW_MS) openLauncher();
        startKeyWatcher();
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
            if (AMAZON_APPSTORE.contentEquals(pkg) && now - lastKeyRedirectAt < KEY_PUSHBACK_MS) {
                // Same push-back the keycode watcher's own redirect already did, for the Appstore's second,
                // delayed page landing back on top a moment later (fire-buttons' own README documents this).
                Log.i(TAG, "Appstore's delayed page came back - pushing it back to " + lastKeyRedirectTarget);
                redirectToConfiguredTarget(lastKeyRedirectTarget);
                return;
            }
            checkButtonRedirect(pkg.toString());
            return;
        }
        // Button redirects can be wanted without replacing the Home button itself (someone who said
        // "no" to the Home-button question but "yes" to remapping app buttons) - this file's presence
        // is universal.sh's way of saying so; its absence (the default) is "yes, redirect Home too",
        // same as before this flag existed.
        if (new File(getFilesDir(), "home_redirect_off").exists()) {
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
    // appearing, and immediately jump elsewhere before the user settles on it - through BlackoutActivity
    // (a plain black, no-animation stopover) rather than straight to the destination, so a solid black
    // frame covers the unwanted app the instant Android can show anything at all, instead of the
    // destination's own (sometimes slower) first frame being the only thing masking it - most noticeable,
    // and most helped by this, when the TV is already lagging. This fires the same way whether the app was
    // opened by its remote button or by its icon on the home screen - Fire OS gives no event data to tell
    // those apart, so this affects the whole app, not just its dedicated button.
    //
    // Configured over adb, no app UI, no rebuild needed. One mapping per line in a plain text file in this
    // app's private internal storage (getFilesDir(), not external/scoped storage - adb's "run-as" reaches
    // that reliably without fighting Android 11's FUSE layer, which blocked external storage here even for
    // run-as). Push a new one with:
    //   adb shell "run-as com.gathin.tvhome mkdir -p files" && adb shell "run-as com.gathin.tvhome sh -c 'cat > files/button_redirects.txt'" < button_redirects.txt
    // Each line is either "source.package=target.package" (or "=OFF") for an app that's installed and
    // enabled - matched by window-watch, same as the Home redirect above - or "KEY<n>=target.package" for
    // a button whose app is NOT installed/enabled, matched by the keycode watcher below instead (see its
    // own comment for why window-watch can't see that case at all). Both forms also accept "=OFF". Blank
    // lines and lines starting with # are ignored. Re-read whenever the file's mtime changes.
    private final Map<String, String> buttonRedirects = new HashMap<>();
    private final Map<Integer, String> buttonRedirectsByKey = new HashMap<>();
    private long buttonRedirectsMtime = -1;

    private void loadButtonRedirectsIfChanged() {
        File f = new File(getFilesDir(), "button_redirects.txt");
        long mtime = f.lastModified();
        if (mtime == buttonRedirectsMtime) return;
        buttonRedirectsMtime = mtime;
        buttonRedirects.clear();
        buttonRedirectsByKey.clear();
        if (mtime == 0) return; // file doesn't exist
        try (BufferedReader r = new BufferedReader(new FileReader(f))) {
            String line;
            while ((line = r.readLine()) != null) {
                line = line.trim();
                if (line.isEmpty() || line.startsWith("#")) continue;
                int eq = line.indexOf('=');
                if (eq <= 0) continue;
                String key = line.substring(0, eq).trim(), target = line.substring(eq + 1).trim();
                if (key.startsWith("KEY")) {
                    try {
                        buttonRedirectsByKey.put(Integer.parseInt(key.substring(3)), target);
                    } catch (NumberFormatException ignored) { }
                } else {
                    buttonRedirects.put(key, target);
                }
            }
            Log.i(TAG, "button_redirects.txt: " + buttonRedirects.size() + " package + "
                    + buttonRedirectsByKey.size() + " keycode mapping(s) loaded");
        } catch (Exception e) {
            Log.w(TAG, "button_redirects.txt: couldn't read it (" + e + ")");
        }
    }

    private void checkButtonRedirect(String pkg) {
        loadButtonRedirectsIfChanged();
        String target = buttonRedirects.get(pkg);
        if (target == null) return;
        Log.i(TAG, pkg + " opened: " + ("OFF".equals(target) ? "bouncing back (configured OFF)" : "redirecting to " + target));
        redirectToConfiguredTarget(target);
    }

    private void redirectToConfiguredTarget(String target) {
        if (target == null || "OFF".equals(target)) {
            openLauncher();
            return;
        }
        Intent launch = getPackageManager().getLaunchIntentForPackage(target);
        if (launch == null) {
            Log.w(TAG, target + " has no launch intent (not installed?) - bouncing back instead");
            openLauncher();
            return;
        }
        launchThroughBlackout(launch, null);
    }

    // ---- keycode-based redirect (button's app not installed/enabled) ------------------------------
    //
    // Window-watch above needs the button's app to actually launch a window for us to see - but when
    // that app is missing or disabled, Fire OS's own key policy (FireTVKeyPolicyManager) opens that
    // app's Amazon Appstore page instead, and never gets as far as a window we could match by package.
    // Fire OS does log the raw press first, though: "KeyPressReceiver: Remote button pressed. keyCode:
    // N" (github.com/enlightened-d/fire-buttons worked this out) - a signal window-watch categorically
    // can't get, since it's gone before any window appears. This tails logcat for that line (needs
    // android.permission.READ_LOGS, force-granted over adb the same way as WRITE_SECURE_SETTINGS: a
    // normal app can't request it, but adb's shell UID can grant it regardless) and redirects the
    // instant it sees a configured keycode - no need to wait for the Appstore page first. Its own
    // delayed second page landing on top a few seconds later is caught by the ordinary window-watch
    // path above (AMAZON_APPSTORE + KEY_PUSHBACK_MS), since by then it's just an ordinary window.
    private static final Pattern KEY_PRESS_LINE = Pattern.compile("Remote button pressed\\. keyCode: (\\d+)");
    private static final long KEY_PUSHBACK_MS = 8_000;
    private volatile Process logcatProcess;
    private Thread keyWatcherThread;
    private long lastKeyRedirectAt = -KEY_PUSHBACK_MS;
    private String lastKeyRedirectTarget;

    private void startKeyWatcher() {
        if (keyWatcherThread != null) return;
        keyWatcherThread = new Thread(this::runKeyWatcher, "HomeRedirect-KeyWatcher");
        keyWatcherThread.setDaemon(true);
        keyWatcherThread.start();
    }

    private void stopKeyWatcher() {
        if (logcatProcess != null) { logcatProcess.destroy(); logcatProcess = null; }
        if (keyWatcherThread != null) { keyWatcherThread.interrupt(); keyWatcherThread = null; }
    }

    private void runKeyWatcher() {
        try {
            logcatProcess = Runtime.getRuntime().exec(new String[]{"logcat", "-v", "brief"});
            try (BufferedReader r = new BufferedReader(new InputStreamReader(logcatProcess.getInputStream()))) {
                String line;
                while ((line = r.readLine()) != null) {
                    Matcher m = KEY_PRESS_LINE.matcher(line);
                    if (!m.find()) continue;
                    int keyCode = Integer.parseInt(m.group(1));
                    loadButtonRedirectsIfChanged();
                    String target = buttonRedirectsByKey.get(keyCode);
                    if (target == null) continue;
                    Log.i(TAG, "keyCode " + keyCode + " pressed (app not installed/enabled): redirecting to " + target);
                    lastKeyRedirectAt = SystemClock.uptimeMillis();
                    lastKeyRedirectTarget = target;
                    handler.post(() -> redirectToConfiguredTarget(target));
                }
            }
        } catch (Exception e) {
            Log.w(TAG, "keycode watcher stopped (" + e + ") - keycode-based remaps (apps not installed) won't fire until the service restarts");
        }
    }

    // Hands a destination Intent off through BlackoutActivity instead of starting it directly, so a
    // plain black frame covers whatever's mid-render on screen as soon as Android can show anything at
    // all, instead of the destination's own first frame being the only thing masking it. No fixed delay:
    // BlackoutActivity finishes itself right after the hand-off, and Android keeps its black content up
    // until the destination actually has a frame ready to replace it, same as any other activity
    // transition with no animation telling it to do otherwise. fallback (nullable) is tried if primary
    // doesn't actually start (not installed, SecurityException, etc).
    private void launchThroughBlackout(Intent primary, Intent fallback) {
        Intent via = new Intent(this, BlackoutActivity.class)
                .putExtra(BlackoutActivity.EXTRA_TARGET, primary.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NO_ANIMATION))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NO_ANIMATION);
        if (fallback != null) {
            via.putExtra(BlackoutActivity.EXTRA_FALLBACK, fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NO_ANIMATION));
        }
        startActivity(via);
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
        launchThroughBlackout(
                new Intent().setComponent(new ComponentName(REDIRECT_PACKAGE, REDIRECT_ACTIVITY)),
                new Intent(this, MainActivity.class));
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
