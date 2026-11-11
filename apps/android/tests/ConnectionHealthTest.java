package io.github.weqdevs.remote;

public final class ConnectionHealthTest {
    public static void main(String[] args) {
        ConnectionHealth health = new ConnectionHealth();
        check("待检查".equals(health.status()));
        health.failed(); check(!health.suspected);
        health.suspend(); health.failed(); check(!health.suspected);
        health.failed(); check(health.suspected);
        health.suspend(); check(health.suspected);
        health.succeeded(100, 42L);
        check("已连接".equals(health.status()) && health.checkedAt == 100 && health.latency == 42);
        health.failed(); check(!health.suspected && health.checkedAt == 100);
    }
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
}
