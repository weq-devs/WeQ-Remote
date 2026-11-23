
extern int WeQOpenGateway(const char *, const char *, const char *, const char *);
extern char *WeQGatewayOrigin(int);
extern int WeQGatewayHasRelease(int);
extern int WeQAttachGateway(int, int, const char *, const char *);
extern void WeQCloseGateway(int);
extern void WeQClearGatewayCache(const char *);
