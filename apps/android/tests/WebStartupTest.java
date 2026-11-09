package io.github.weqdevs.remote;

public final class WebStartupTest {
    public static void main(String[] args) {
        check(WebStartup.shouldOpenWeb(true, false, false));
        check(WebStartup.shouldOpenWeb(false, true, false));
        // 页面是否就绪与代理是否存在是两件事；初始化中返回前台仍应保留原页。
        check(!WebStartup.shouldOpenWeb(false, true, true));
        check(!WebStartup.shouldOpenWeb(false, false, false));
        check(WebStartup.consoleProblem("Uncaught SyntaxError: Unexpected token '?'").contains("无法解析"));
        check(WebStartup.consoleProblem("Failed to load module script: MIME type text/html").contains("格式不正确"));
        check(WebStartup.consoleProblem("Refused due to Content Security Policy").contains("被阻止"));
        String sensitive = "Uncaught TypeError: private-token private-message";
        check(WebStartup.consoleProblem(sensitive).contains("脚本异常"));
        check(!WebStartup.consoleProblem(sensitive).contains("private"));
        check(WebStartup.consoleProblem("a harmless application log") == null);
        check(WebStartup.consoleProblem(null) == null);
        check(WebStartup.resourceProblem("/assets/index-test.js", 404).contains("HTTP 404"));
        check(WebStartup.resourceProblem("/assets/theme-test.css", 0).contains("资源加载失败"));
        check(WebStartup.resourceProblem("/_media/photo.js", 404) == null);
        check(WebStartup.resourceProblem("/assets/decoration.png", 404) == null);
        check(WebStartup.resourceProblem(null, 404) == null);
        System.out.println("WebStartup tests passed");
    }
    static void check(boolean value) { if (!value) throw new AssertionError(); }
}
