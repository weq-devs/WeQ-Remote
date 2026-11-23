package io.github.weqdevs.remote;

import java.util.Locale;

/** 初始化失败只展示固定诊断，不把控制台中的凭据或业务原文带到连接首页。 */
final class WebStartup {
    static boolean shouldOpenWeb(boolean restoring, boolean hasPage, boolean hasProxy) {
        return restoring || hasPage && !hasProxy;
    }

    static String consoleProblem(String message) {
        if (message == null) return null;
        String text = message.toLowerCase(Locale.ROOT);
        if (text.contains("syntaxerror") || text.contains("unexpected token") || text.contains("unexpected identifier"))
            return "WeQ 网页脚本无法解析，请更新手机的 Android System WebView 或 Chrome 后重试。";
        if (text.contains("content security policy") || text.contains("mime type") || text.contains("module script"))
            return "WeQ 网页脚本被阻止或资源格式不正确。";
        if (text.contains("uncaught") && (text.contains("typeerror") || text.contains("referenceerror") || text.contains("error:")))
            return "WeQ 网页初始化时出现脚本异常。";
        return null;
    }

    static String resourceProblem(String path, int status) {
        if (path == null || !path.startsWith("/assets/") || !(path.endsWith(".js") || path.endsWith(".css"))) return null;
        return "WeQ 网页代码资源加载失败" + (status > 0 ? "（HTTP " + status + "）" : "") + "。";
    }
}
