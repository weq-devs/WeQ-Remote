package io.github.weqdevs.remote;

final class ConnectionHealth {
    private int failures;
    boolean suspected;
    long checkedAt;
    Long latency;

    String status() { return suspected ? "连接已中断" : checkedAt == 0 ? "待检查" : "已连接"; }
    void succeeded(long now, Long milliseconds) {
        failures = 0; suspected = false; checkedAt = now; latency = milliseconds;
    }
    void failed() { failures = Math.min(failures + 1, 2); suspected = suspected || failures >= 2; }
    void suspend() { failures = 0; }
}
