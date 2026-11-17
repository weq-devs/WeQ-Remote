package io.github.weqdevs.remote;

final class WebResourceProgress {
    static final String PREPARING_MESSAGE = "正在准备网页资源";
    final int completed, total;
    WebResourceProgress(int completed, int total) {
        if (total <= 0 || total > 4096 || completed < 0 || completed > total)
            throw new IllegalArgumentException("invalid resource progress");
        this.completed = completed; this.total = total;
    }
    static int count(Object value) {
        if (!(value instanceof Number)) throw new IllegalArgumentException("invalid resource count");
        double number = ((Number) value).doubleValue();
        if (number < 0 || number > 4096 || number != Math.rint(number))
            throw new IllegalArgumentException("invalid resource count");
        return (int) number;
    }
    String stage() { return completed < total ? PREPARING_MESSAGE : "正在初始化网页"; }
    String detail() { return "网页资源已就绪 " + completed + " / " + total + " 项"; }
}
