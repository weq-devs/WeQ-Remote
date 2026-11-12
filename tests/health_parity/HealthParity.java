package io.github.weqdevs.remote;

import java.io.BufferedReader;
import java.io.InputStreamReader;

public final class HealthParity {
    public static void main(String[] args) throws Exception {
        ConnectionHealth health = new ConnectionHealth();
        BufferedReader reader = new BufferedReader(new InputStreamReader(System.in));
        String line;
        while ((line = reader.readLine()) != null) {
            String[] fields = line.split("\t");
            long now = Long.parseLong(fields[1]);
            switch (fields[0]) {
                case "resume": health.resume(now); break;
                case "suspend": health.suspend(); break;
                case "begin": health.beginCheck(now); break;
                case "failed": health.failed(now); break;
                case "checkFailed": health.checkFailed(now); break;
                case "network": health.networkChanged("1".equals(fields[2]), now); break;
                case "evaluate": health.evaluate(now); break;
                case "success": health.succeeded(100, 42L, now); break;
                default: throw new AssertionError("unknown operation");
            }
            Long deadline = health.nextDeadline();
            System.out.println(health.state() + "\t" + health.requestTimeout() + "\t" + (deadline == null ? -1 : deadline));
        }
    }
}
