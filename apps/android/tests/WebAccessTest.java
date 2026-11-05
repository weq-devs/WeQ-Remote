package io.github.weqdevs.remote;

public final class WebAccessTest {
    public static void main(String[] args) {
        check(WebAccess.sameOrigin("http://127.0.0.1:1234", "http://127.0.0.1:1234/_download/id"));
        check(!WebAccess.sameOrigin("http://127.0.0.1:1234", "http://127.0.0.1:1235/_download/id"));
        check(!WebAccess.sameOrigin("https://host", "https://secret@host/path"));
        check(WebAccess.sameOrigin("https://host", "https://host:443/path"));
        check(WebAccess.external("https://example.com/path"));
        check(WebAccess.external("mailto:test@example.com"));
        for (String value : new String[]{"javascript:alert(1)", "file:///private/file", "intent://host", "https://secret@example.com", "data:text/html,test"}) check(!WebAccess.external(value));
        check(WebAccess.fileName("../file.txt").equals("file.txt"));
        check(WebAccess.fileName("..").equals("download"));
        System.out.println("WebAccess tests passed");
    }
    static void check(boolean value) { if (!value) throw new AssertionError(); }
}
