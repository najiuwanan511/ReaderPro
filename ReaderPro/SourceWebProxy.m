#import "SourceWebProxy.h"
#import <Network/Network.h>

BOOL RPSetWebProxy(WKWebsiteDataStore *store, NSString *host, uint16_t port,
                   BOOL socks5, NSString *username, NSString *password) {
    if (!host) {
        store.proxyConfigurations = nil;
        return YES;
    }
    nw_endpoint_t endpoint = nw_endpoint_create_host(host.UTF8String,
                                                    [@(port).stringValue UTF8String]);
    nw_proxy_config_t proxy = socks5 ? nw_proxy_config_create_socksv5(endpoint)
                                    : nw_proxy_config_create_http_connect(endpoint, NULL);
    if (!proxy) return NO;
    nw_proxy_config_clear_excluded_domains(proxy);
    nw_proxy_config_add_match_domain(proxy, "");
    nw_proxy_config_set_failover_allowed(proxy, false);
    if (username) {
        nw_proxy_config_set_username_and_password(proxy, username.UTF8String,
                                                   password.UTF8String);
    }
    store.proxyConfigurations = @[proxy];
    return YES;
}
