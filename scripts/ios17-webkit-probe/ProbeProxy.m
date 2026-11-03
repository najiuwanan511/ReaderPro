#import <WebKit/WebKit.h>
#import <Network/Network.h>

// iOS 17's retained per-store session configuration, compared independently
// with the newer public live Network configuration. No process-wide changes.
@interface NSObject (RPProbeStoreConfiguration)
- (instancetype)initNonPersistentConfiguration;
- (void)setProxyConfiguration:(NSDictionary *)configuration;
- (instancetype)_initWithConfiguration:(id)configuration;
@end

WKWebsiteDataStore *RPProbeLegacyStore(BOOL socks) {
    Class cls = NSClassFromString(@"_WKWebsiteDataStoreConfiguration");
    if (!cls || ![cls instancesRespondToSelector:@selector(initNonPersistentConfiguration)] ||
        ![cls instancesRespondToSelector:@selector(setProxyConfiguration:)] ||
        ![WKWebsiteDataStore instancesRespondToSelector:@selector(_initWithConfiguration:)]) return nil;
    id configuration = [[cls alloc] initNonPersistentConfiguration];
    NSDictionary *proxy = socks ? @{@"SOCKSEnable": @YES, @"SOCKSProxy": @"127.0.0.1", @"SOCKSPort": @8769,
                                    @"SOCKSUser": @"fixture-user", @"SOCKSPassword": @"fixture-pass"}
                               : @{@"HTTPEnable": @YES, @"HTTPProxy": @"127.0.0.1", @"HTTPPort": @8765,
                                   @"HTTPSEnable": @YES, @"HTTPSProxy": @"127.0.0.1", @"HTTPSPort": @8765};
    [configuration setProxyConfiguration:proxy];
    return [[WKWebsiteDataStore alloc] _initWithConfiguration:configuration];
}

// Controls for Apple's untouched default matching and one explicit hostname.
// This does not replace or alter ReaderPro's production bridge.
BOOL RPProbeSetDefaultProxy(WKWebsiteDataStore *store, BOOL socks, BOOL exactMatch) {
    nw_endpoint_t endpoint = nw_endpoint_create_host("127.0.0.1", socks ? "8769" : "8765");
    nw_proxy_config_t proxy = socks ? nw_proxy_config_create_socksv5(endpoint)
                                    : nw_proxy_config_create_http_connect(endpoint, NULL);
    if (!proxy) return NO;
    if (exactMatch) {
        nw_proxy_config_clear_excluded_domains(proxy);
        nw_proxy_config_add_match_domain(proxy, socks ? "192.0.2.1" : "readerproxy.invalid");
    }
    nw_proxy_config_set_failover_allowed(proxy, false);
    if (socks) nw_proxy_config_set_username_and_password(proxy, "fixture-user", "fixture-pass");
    store.proxyConfigurations = @[proxy];
    return YES;
}
