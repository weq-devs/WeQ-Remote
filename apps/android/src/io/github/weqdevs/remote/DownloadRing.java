package io.github.weqdevs.remote;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.view.View;

/** 清单字节权重表示资源加载比例，不表示本次网络下载比例。 */
final class DownloadRing extends View {
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF bounds = new RectF();
    private final int accent;
    private WebDownloadProgress progress;
    DownloadRing(Context context, int accent) { super(context); this.accent = accent; setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO); }
    void update(WebDownloadProgress value) {
        boolean redraw = progress == null || value == null
            ? progress != value
            : progress.fraction() != value.fraction() || progress.percentage() != value.percentage();
        progress = value;
        if (redraw) invalidate();
    }
    @Override protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        float density = getResources().getDisplayMetrics().density;
        float stroke = progress == null ? density : 4 * density;
        float inset = stroke / 2;
        bounds.set(inset, inset, getWidth() - inset, getHeight() - inset);
        paint.setStyle(Paint.Style.STROKE); paint.setStrokeWidth(stroke);
        paint.setColor(Color.argb(41, Color.red(accent), Color.green(accent), Color.blue(accent)));
        canvas.drawOval(bounds, paint);
        if (progress == null) return;
        paint.setColor(accent); paint.setStrokeCap(Paint.Cap.ROUND);
        canvas.drawArc(bounds, -90, 360 * progress.fraction(), false, paint);
        paint.setStyle(Paint.Style.FILL); paint.setTextAlign(Paint.Align.CENTER);
        paint.setTextSize(12 * getResources().getDisplayMetrics().scaledDensity);
        float labelSize = paint.getTextSize();
        float available = getWidth() - 32 * density;
        float labelWidth = paint.measureText("资源加载");
        if (labelWidth > available) paint.setTextSize(labelSize * available / labelWidth);
        float labelBottom = getHeight() / 2f - 6 * density;
        canvas.drawText("资源加载", getWidth() / 2f, labelBottom, paint);
        paint.setTextSize(22 * getResources().getDisplayMetrics().scaledDensity);
        String percentage = progress.percentage() + "%";
        float width = paint.measureText(percentage);
        if (width > available) paint.setTextSize(paint.getTextSize() * available / width);
        canvas.drawText(percentage, getWidth() / 2f, labelBottom - paint.ascent() + 4 * density, paint);
    }
}
