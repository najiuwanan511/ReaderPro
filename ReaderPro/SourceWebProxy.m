#import "SourceWebProxy.h"
#import <Network/Network.h>
#import <objc/runtime.h>

@interface NSObject (RPStoreProxyCreation)
- (instancetype)initNonPersistentConfiguration;
- (void)setProxyConfiguration:(NSDictionary *)configuration;
- (instancetype)_initWithConfiguration:(id)configuration;
@end

static char RPLegacyProxyKey;
static char RPConfiguredProxyKey;
static NSDictionary *RPProxyIdentity(NSString *host, uint16_t port, BOOL socks5,
                                     NSString *username, NSString *password) {
    return @{@"host": host, @"port": @(port), @"socks": @(socks5),
             @"user": username ?: @"", @"password": password ?: @""};
}

WKWebsiteDataStore *RPCreateLegacyWebProxyStore(NSString *host, uint16_t port,
                    BOOL socks5, NSString *username, NSString *password) {
    Class cls = NSClassFromString(@"_WKWebsiteDataStoreConfiguration");
    if (!cls || ![cls instancesRespondToSelector:@selector(initNonPersistentConfiguration)] ||
        ![cls instancesRespondToSelector:@selector(setProxyConfiguration:)] ||
        ![WKWebsiteDataStore instancesRespondToSelector:@selector(_initWithConfiguration:)]) return nil;
    id configuration = [[cls alloc] initNonPersistentConfiguration];
    NSMutableDictionary *proxy = socks5
        ? [@{@"SOCKSEnable": @YES, @"SOCKSProxy": host, @"SOCKSPort": @(port)} mutableCopy]
        : [@{@"HTTPEnable": @YES, @"HTTPProxy": host, @"HTTPPort": @(port),
             @"HTTPSEnable": @YES, @"HTTPSProxy": host, @"HTTPSPort": @(port)} mutableCopy];
    if (socks5 && username) {
        proxy[@"SOCKSUser"] = username; proxy[@"SOCKSPassword"] = password ?: @"";
    }
    [configuration setProxyConfiguration:proxy];
    WKWebsiteDataStore *store = [[WKWebsiteDataStore alloc] _initWithConfiguration:configuration];
    if (store) {
        NSDictionary *identity = RPProxyIdentity(host, port, socks5, username, password);
        objc_setAssociatedObject(store, &RPLegacyProxyKey, identity, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(store, &RPConfiguredProxyKey, identity, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return store;
}

NSURLCredential *RPWebProxyCredential(WKWebsiteDataStore *store, NSURLAuthenticationChallenge *challenge) {
    NSDictionary *proxy = objc_getAssociatedObject(store, &RPConfiguredProxyKey);
    NSURLProtectionSpace *space = challenge.protectionSpace;
    if (!proxy || ![space isProxy] || challenge.previousFailureCount != 0 ||
        ![proxy[@"user"] length] || [space.host caseInsensitiveCompare:proxy[@"host"]] != NSOrderedSame ||
        space.port != [proxy[@"port"] integerValue] ||
        ![@[NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest] containsObject:space.authenticationMethod]) return nil;
    return [NSURLCredential credentialWithUser:proxy[@"user"] password:proxy[@"password"] persistence:NSURLCredentialPersistenceForSession];
}

BOOL RPSetWebProxy(WKWebsiteDataStore *store, NSString *host, uint16_t port,
                   BOOL socks5, NSString *username, NSString *password) {
    NSDictionary *legacy = objc_getAssociatedObject(store, &RPLegacyProxyKey);
    if (legacy) {
        // A retained session is immutable. Never pretend to clear/retarget it,
        // or install a live setting that iOS 17 would then ignore.
        return host && [legacy isEqual:RPProxyIdentity(host, port, socks5, username, password)];
    }
    if (!host) {
        store.proxyConfigurations = nil;
        objc_setAssociatedObject(store, &RPConfiguredProxyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return YES;
    }
    nw_endpoint_t endpoint = nw_endpoint_create_host(host.UTF8String,
                                                    [@(port).stringValue UTF8String]);
    nw_proxy_config_t proxy = socks5 ? nw_proxy_config_create_socksv5(endpoint)
                                    : nw_proxy_config_create_http_connect(endpoint, NULL);
    if (!proxy) return NO;
    nw_proxy_config_clear_excluded_domains(proxy);
    // Explicitly match all destinations on the public iOS 18+ path.
    nw_proxy_config_clear_match_domains(proxy);
    nw_proxy_config_add_match_domain(proxy, "");
    nw_proxy_config_set_failover_allowed(proxy, false);
    if (username) {
        nw_proxy_config_set_username_and_password(proxy, username.UTF8String,
                                                   password.UTF8String);
    }
    store.proxyConfigurations = @[proxy];
    objc_setAssociatedObject(store, &RPConfiguredProxyKey, RPProxyIdentity(host, port, socks5, username, password), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}
