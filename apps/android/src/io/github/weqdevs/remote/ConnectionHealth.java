package io.github.weqdevs.remote;

final class ConnectionHealth {
    private long failures;
    private Long lastResponse, failureSince, noNetworkSince, retryWarningAt;
    boolean networkAvailable = true;
    boolean suspected;
    long checkedAt;
    Long latency;

    long requestTimeout() { return 5000 * (failures + 1); }
    long checkInterval() { return failures == 0 ? 15000 : 500; }
    boolean recovering() { return failures > 0; }
    String state() { return suspected ? (!networkAvailable ? "network" : "connection") : "connected"; }
    void beginCheck(long now) { if (failures > 0 && retryWarningAt == null) retryWarningAt = now + 5000; }
    void resume(long now) { lastResponse = now; failureSince = null; retryWarningAt = null; failures = 0; noNetworkSince = networkAvailable ? null : now; }
    void networkChanged(boolean available, long now) {
        networkAvailable = available;
        if (available) noNetworkSince = null;
        else if (noNetworkSince == null) noNetworkSince = now;
    }
    Long nextDeadline() {
        if (suspected) return null;
        Long result = lastResponse == null ? null : lastResponse + 30000;
        for (Long candidate : new Long[]{failureSince == null ? null : failureSince + 10000,
                noNetworkSince == null ? null : noNetworkSince + 10000, retryWarningAt})
            if (candidate != null && (result == null || candidate < result)) result = candidate;
        return result;
    }
    void evaluate(long now) { Long deadline = nextDeadline(); if (deadline != null && now >= deadline) suspected = true; }

    String status() { return suspected ? (!networkAvailable ? "网络已断开" : "连接已中断") : checkedAt == 0 ? "待检查" : "已连接"; }
    void succeeded(long date, Long milliseconds, long now) {
        failures = 0; suspected = false; checkedAt = date; latency = milliseconds;
        lastResponse = now; failureSince = null; noNetworkSince = null; retryWarningAt = null;
    }
    void failed(long now) { if (failureSince == null) failureSince = now; }
    void checkFailed(long now) { failures++; failed(now); }
    void suspend() { lastResponse = null; failureSince = null; noNetworkSince = null; retryWarningAt = null; }
}
