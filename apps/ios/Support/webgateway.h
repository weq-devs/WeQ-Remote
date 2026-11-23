
extern int WeQOpenGateway(const char *, const char *, const char *, const char *);
extern char *WeQGatewayOrigin(int);
extern int WeQGatewayHasRelease(int);
extern int WeQAttachGateway(int, int, const char *, const char *, const char *);
extern void WeQSetGatewayRelease(int, const char *);
extern int WeQReloadGateway(int);
extern int WeQStoreGatewayImage(int, const char *, const char *, const unsigned char *, int);
extern void WeQCloseGateway(int);
extern void WeQClearGatewayCache(const char *);
