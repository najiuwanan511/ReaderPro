#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN
// Use the public Objective-C property rather than WebKit's Swift overlay.
// The overlay links libswiftWebKit, which is absent on some iOS 17 runtimes.
BOOL RPSetWebProxy(WKWebsiteDataStore *store, NSString * _Nullable host,
                   uint16_t port, BOOL socks5, NSString * _Nullable username,
                   NSString * _Nullable password);
// iOS 17 needs the proxy in the session's creation parameters. This optional
// per-store compatibility path never changes a process-wide proxy setting.
WKWebsiteDataStore * _Nullable RPCreateLegacyWebProxyStore(NSString *host, uint16_t port,
                    BOOL socks5, NSString * _Nullable username, NSString * _Nullable password);
NSURLCredential * _Nullable RPWebProxyCredential(WKWebsiteDataStore *store, NSURLAuthenticationChallenge *challenge);
NS_ASSUME_NONNULL_END
