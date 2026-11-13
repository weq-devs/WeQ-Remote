package io.github.weqdevs.remote;

public final class NetworkCostTest {
    public static void main(String[] args) {
        NetworkCost unknown = new NetworkCost(false, false, false);
        if (!unknown.state().equals("unknown") || unknown.reduce("auto")) throw new AssertionError();
        for (NetworkCost cost : new NetworkCost[] { new NetworkCost(true, true, false), new NetworkCost(true, false, true) }) {
            if (!cost.state().equals("restricted") || !cost.reduce("auto") || cost.reduce("never")) throw new AssertionError();
        }
        NetworkCost free = new NetworkCost(true, false, false);
        if (!free.state().equals("unrestricted") || free.reduce("auto") || !free.reduce("always")) throw new AssertionError();
        System.out.println("Network cost tests passed");
    }
}
