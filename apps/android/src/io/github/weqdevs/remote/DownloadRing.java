package io.github.weqdevs.remote;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.view.View;

/** 沿用连接页外环，下载比例按已完成资源的字节数计算。 */
final class DownloadRing extends View {
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final int accent;
    private WebDownloadProgress progress;
    DownloadRing(Context context, int accent) { super(context); this.accent = accent; setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO); }
    void update(WebDownloadProgress value) { progress = value; invalidate(); }
    @Override protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        float density = getResources().getDisplayMetrics().density;
        float stroke = progress == null ? density : 4 * density;
        float inset = stroke / 2;
        RectF bounds = new RectF(inset, inset, getWidth() - inset, getHeight() - inset);
        paint.setStyle(Paint.Style.STROKE); paint.setStrokeWidth(stroke);
        paint.setColor(Color.argb(41, Color.red(accent), Color.green(accent), Color.blue(accent)));
        canvas.drawOval(bounds, paint);
        if (progress == null) return;
        paint.setColor(accent); paint.setStrokeCap(Paint.Cap.ROUND);
        canvas.drawArc(bounds, -90, 360 * progress.fraction(), false, paint);
        paint.setStyle(Paint.Style.FILL); paint.setTextAlign(Paint.Align.CENTER);
        paint.setTextSize(22 * getResources().getDisplayMetrics().scaledDensity);
        String percentage = Math.round(progress.fraction() * 100) + "%";
        float width = paint.measureText(percentage), available = getWidth() - 32 * density;
        if (width > available) paint.setTextSize(paint.getTextSize() * available / width);
        canvas.drawText(percentage, getWidth() / 2f, (getHeight() - paint.ascent() - paint.descent()) / 2f, paint);
    }
}
