package io.freemytv;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

/**
 * Unsplash's attribution requirement (guideline 3): "Photo by {name} on Unsplash", linked to the photographer's
 * profile. RandomPhotos writes one of these beside each photo it imports; HomeView and DreamView read it back to
 * draw the credit over that photo. Absent for every other photo (tools/photos.py's, Immich's): nothing to show.
 */
final class Attribution {
    private Attribution() {}

    static File sidecar(File photo) {
        String name = photo.getName();
        int dot = name.lastIndexOf('.');
        return new File(photo.getParentFile(), (dot < 0 ? name : name.substring(0, dot)) + ".credit");
    }

    /** {name, profileUrl}, or null when this photo has no Unsplash credit to show. */
    static String[] of(File photo) {
        if (photo == null) return null;
        File f = sidecar(photo);
        if (!f.isFile()) return null;
        try (FileInputStream in = new FileInputStream(f)) {
            byte[] buf = new byte[4096];
            int n = in.read(buf);
            if (n <= 0) return null;
            String[] lines = new String(buf, 0, n, StandardCharsets.UTF_8).split("\n", 2);
            return lines.length == 2 ? lines : null;
        } catch (IOException e) {
            return null;
        }
    }
}
