package io.github.weqdevs.remote;

import java.util.List;

final class ReleaseCatalog {
    final String tag;
    final ReleaseVersion version;
    private ReleaseCatalog(String tag, ReleaseVersion version) { this.tag = tag; this.version = version; }
    static final class Entry {
        final String tag;
        final boolean draft, prerelease, published, hasManifest;
        Entry(String tag, boolean draft, boolean prerelease, boolean published, boolean hasManifest) {
            this.tag = tag; this.draft = draft; this.prerelease = prerelease; this.published = published; this.hasManifest = hasManifest;
        }
    }
    static ReleaseCatalog select(List<Entry> releases, boolean includePrerelease) throws Exception {
        ReleaseCatalog best = null;
        for (Entry release : releases) {
            String tag = release.tag;
            ReleaseVersion version = tag.startsWith("v") ? ReleaseVersion.parse(tag.substring(1)) : null;
            if (version == null || release.draft || !release.published) continue;
            if (!includePrerelease && (release.prerelease || version.beta != null)) continue;
            if (release.hasManifest && (best == null || version.compareTo(best.version) > 0)) best = new ReleaseCatalog(tag, version);
        }
        if (best == null) throw new Exception("no published release");
        return best;
    }
}
