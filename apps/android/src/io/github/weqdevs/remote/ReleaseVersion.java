package io.github.weqdevs.remote;

final class ReleaseVersion implements Comparable<ReleaseVersion> {
    final String text;
    final long[] parts;
    final Long beta;
    private ReleaseVersion(String text, long[] parts, Long beta) { this.text = text; this.parts = parts; this.beta = beta; }
    static ReleaseVersion parse(String text) {
        if (text == null || !text.matches("(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(b[1-9][0-9]*)?")) return null;
        try {
            String[] pieces = text.split("b"), numbers = pieces[0].split("\\.");
            return new ReleaseVersion(text, new long[]{Long.parseLong(numbers[0]), Long.parseLong(numbers[1]), Long.parseLong(numbers[2])}, pieces.length == 2 ? Long.parseLong(pieces[1]) : null);
        } catch (NumberFormatException invalid) { return null; }
    }
    public int compareTo(ReleaseVersion other) {
        for (int i = 0; i < parts.length; i++) { int result = Long.compare(parts[i], other.parts[i]); if (result != 0) return result; }
        return beta == null ? other.beta == null ? 0 : 1 : other.beta == null ? -1 : Long.compare(beta, other.beta);
    }
}
