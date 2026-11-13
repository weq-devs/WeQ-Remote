package io.github.weqdevs.remote;

final class NetworkCost {
    final boolean available, constrained, metered;
    NetworkCost(boolean available, boolean constrained, boolean metered) {
        this.available = available; this.constrained = constrained; this.metered = metered;
    }
    String state() { return !available ? "unknown" : constrained || metered ? "restricted" : "unrestricted"; }
    boolean reduce(String mode) { return mode.equals("always") || (!mode.equals("never") && state().equals("restricted")); }
}
