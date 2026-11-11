package com.gathin.tvhome;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.os.Bundle;
import android.util.Log;

/**
 * A plain black, no-animation stopover between "the unwanted app's window just appeared" and
 * "the real destination is up". Covers the screen the instant Android can show *anything* for
 * this activity, instead of leaving the destination's own first frame - which can be slower,
 * especially when the TV is already lagging - as the only thing masking the unwanted app. Tries
 * EXTRA_TARGET, falls back to EXTRA_FALLBACK if that fails to start, then finishes either way.
 */
public class BlackoutActivity extends Activity {

    static final String EXTRA_TARGET = "target";
    static final String EXTRA_FALLBACK = "fallback";
    private static final String TAG = "HomeRedirect";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Intent target = getIntent().getParcelableExtra(EXTRA_TARGET);
        if (!tryStart(target)) {
            tryStart((Intent) getIntent().getParcelableExtra(EXTRA_FALLBACK));
        }
        finish();
        overridePendingTransition(0, 0);
    }

    private boolean tryStart(Intent intent) {
        if (intent == null) return false;
        try {
            startActivity(intent);
            return true;
        } catch (ActivityNotFoundException | SecurityException e) {
            Log.w(TAG, "blackout hand-off to " + intent + " failed (" + e + ")");
            return false;
        }
    }
}
