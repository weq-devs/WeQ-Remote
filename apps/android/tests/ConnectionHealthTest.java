package io.github.weqdevs.remote;

public final class ConnectionHealthTest {
    public static void main(String[] args) {
        ConnectionHealth health = new ConnectionHealth();
        health.resume(0);
        check(health.requestTimeout() == 5000);
        health.beginCheck(0); health.checkFailed(5000);
        check(!health.suspected && health.requestTimeout() == 10000);
        health.beginCheck(5000);
        check(health.nextDeadline() == 10000);
        health.evaluate(9999); check(!health.suspected);
        health.evaluate(10000); check(health.suspected);
        check(health.requestTimeout() == 10000);
        health.checkFailed(15000); check(health.requestTimeout() == 15000);
        health.beginCheck(15000); health.checkFailed(30000);
        check(health.requestTimeout() == 20000);
        health.succeeded(100, 42L, 31000);
        check(!health.suspected && health.requestTimeout() == 5000 && health.checkInterval() == 15000);
        check(health.checkedAt == 100 && health.latency == 42);

        health.resume(0); health.networkChanged(false, 1000); health.networkChanged(false, 3000);
        health.evaluate(10999); check(!health.suspected);
        health.evaluate(11000); check("network".equals(health.state()));
        health.networkChanged(true, 12000); check("connection".equals(health.state()));
        health.succeeded(100, 10L, 13000); check(!health.suspected);

        health.resume(0); health.networkChanged(false, 1000); health.networkChanged(true, 2000);
        health.checkFailed(5000); health.beginCheck(5000); health.succeeded(100, 10L, 9000);
        health.evaluate(10000); check(!health.suspected);

        health.resume(0); health.failed(1000); health.failed(8000);
        health.evaluate(11000); check(health.suspected);
        health.succeeded(100, 10L, 12000); health.evaluate(41999); check(!health.suspected);
        health.evaluate(42000); check(health.suspected);
        health.succeeded(100, 10L, 43000);

        health.resume(0); health.checkFailed(1000); health.beginCheck(2000); health.suspend();
        health.evaluate(100000); check(!health.suspected);
        health.resume(100000); check(health.requestTimeout() == 5000);
        health.evaluate(130000); check(health.suspected);
        health.suspend(); health.resume(500000); check(health.suspected);
    }
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
}
