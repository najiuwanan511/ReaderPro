#import <WebKit/WebKit.h>
#import <Network/Network.h>

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
