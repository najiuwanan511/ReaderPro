#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN
// Use the public Objective-C property rather than WebKit's Swift overlay.
// The overlay links libswiftWebKit, which is absent on some iOS 17 runtimes.
BOOL RPSetWebProxy(WKWebsiteDataStore *store, NSString * _Nullable host,
                   uint16_t port, BOOL socks5, NSString * _Nullable username,
                   NSString * _Nullable password);
NS_ASSUME_NONNULL_END
