package io.github.weqdevs.remote;

import android.graphics.Color;
import java.util.Locale;

final class ThemeAccent {
    // 与 WeQ 外观设置的预设顺序和色值一致。
    static final String[] PRESETS = {"#0099ff", "#3b82f6", "#6f8aa6", "#16b8a6", "#32b67a", "#f59e0b", "#ef4444", "#ec4899", "#8b5cf6"};
    static final String[] NAMES = {"默认亮蓝", "蓝色", "灰蓝", "青绿", "绿色", "琥珀", "红色", "粉色", "紫色"};
    static final String DEFAULT = PRESETS[0];

    static String fromStatus(Object value) {
        if (!(value instanceof String)) return null;
        String hex = (String) value;
        return hex.isEmpty() || hex.matches("#[0-9a-fA-F]{6}") ? hex.toLowerCase(Locale.ROOT) : null;
    }

    static String preset(String value) {
        for (String preset : PRESETS) if (preset.equals(value)) return preset;
        return DEFAULT;
    }

    static int fill(String hex, boolean dark) {
        return Color.parseColor(hex.isEmpty() ? (dark ? "#56a8f7" : DEFAULT) : hex);
    }

    static int onFill(int fill) { return luminance(fill) >= 0.179 ? Color.BLACK : Color.WHITE; }
    static int tint(int accent, int alpha) { return Color.argb(alpha, Color.red(accent), Color.green(accent), Color.blue(accent)); }

    static int readable(int fill, boolean dark) {
        double background = luminance(mix(dark ? 0xff242628 : 0xfff5f7f7, fill, 0.12)) + 0.05;
        int target = dark ? Color.WHITE : Color.BLACK;
        for (int step = 0; step <= 20; step++) {
            int ink = mix(fill, target, step / 20.0);
            double value = luminance(ink) + 0.05;
            if (Math.max(value, background) / Math.min(value, background) >= 4.5) return ink;
        }
        return target;
    }

    private static double linear(int value) {
        double channel = value / 255.0;
        return channel <= 0.04045 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4);
    }

    private static double luminance(int color) {
        return 0.2126 * linear(Color.red(color)) + 0.7152 * linear(Color.green(color)) + 0.0722 * linear(Color.blue(color));
    }

    private static int mix(int a, int b, double amount) {
        return Color.rgb((int) Math.round(Color.red(a) + (Color.red(b) - Color.red(a)) * amount),
            (int) Math.round(Color.green(a) + (Color.green(b) - Color.green(a)) * amount),
            (int) Math.round(Color.blue(a) + (Color.blue(b) - Color.blue(a)) * amount));
    }
}
