package io.github.weqdevs.remote;

import android.graphics.Rect;
import android.os.Build;
import android.view.WindowInsets;

final class WindowInsetsHelper {
    private WindowInsetsHelper() { }

    @SuppressWarnings("deprecation")
    static Rect contentInsets(WindowInsets insets) {
        if (Build.VERSION.SDK_INT >= 30) return Api30.contentInsets(insets);
        // 旧系统沿用 adjustResize 和系统窗口 inset，不加载 API 30 的类型。
        return new Rect(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(),
            insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
    }

    @android.annotation.TargetApi(30)
    private static final class Api30 {
        static Rect contentInsets(WindowInsets insets) {
            android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.ime());
            return new Rect(bars.left, bars.top, bars.right, bars.bottom);
        }
    }
}
