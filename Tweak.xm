#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import "GABLog.h"

#define kGABDefaultsDomain @"com.globaladblocker.settings"
#define kGABAppEnabledPrefix @"GABAppEnabled_"
#define kGABDarwinNotification @"com.globaladblocker.settingsChanged"
#define kGABMasterSwitchKey @"GABMasterEnabled"

// Tweak 主体：注入器自动映射 /var/jb/ 前缀 → 真实路径
#define kGABDefaultRulesPath @"/var/jb/Library/PreferenceBundles/GlobalAdBlockerPrefs.bundle/default_rules.json"
// 自定义规则放 jb 外（user 空间），prefs 写入也能读到
#define kGABCustomRulesPath @"/var/mobile/Documents/GlobalAdBlocker/custom_rules.json"

static NSSet *g_exactDomains = nil;
static NSSet *g_suffixDomains = nil;
static BOOL g_rulesLoaded = NO;

// 省电：把 NSUserDefaults 缓存到内存，拦截器每次只查哈希，不读文件
static BOOL g_masterEnabledCache = YES;
static NSMutableSet *g_appEnabledCache = nil;

static void loadRules(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *rulesPath = nil;

    // 优先：自定义规则（Loon 格式，用户导入）
    if ([fm fileExistsAtPath:kGABCustomRulesPath]) {
        rulesPath = kGABCustomRulesPath;
        GABLog(@"使用自定义规则");
    }

    // 其次：默认规则（deb 自带）
    if (!rulesPath) {
        if ([fm fileExistsAtPath:kGABDefaultRulesPath]) {
            rulesPath = kGABDefaultRulesPath;
            GABLog(@"使用默认规则");
        } else {
            // 兼容 prefs 进程视图（无 /var/jb/ 前缀）
            NSString *userPath = @"/Library/PreferenceBundles/GlobalAdBlockerPrefs.bundle/default_rules.json";
            if ([fm fileExistsAtPath:userPath]) {
                rulesPath = userPath;
                GABLog(@"使用默认规则(prefs路径)");
            }
        }
    }

    if (!rulesPath) {
        GABLog(@"未找到规则文件，拦截失效");
        g_exactDomains = [NSSet set];
        g_suffixDomains = [NSSet set];
        g_rulesLoaded = YES;
        return;
    }

    NSData *data = [NSData dataWithContentsOfFile:rulesPath];
    if (!data) {
        GABLog(@"读取规则文件失败: %@", rulesPath);
        g_exactDomains = [NSSet set];
        g_suffixDomains = [NSSet set];
        g_rulesLoaded = YES;
        return;
    }

    NSError *error = nil;
    NSDictionary *rules = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (!rules || error) {
        GABLog(@"解析规则失败: %@", error);
        g_exactDomains = [NSSet set];
        g_suffixDomains = [NSSet set];
        g_rulesLoaded = YES;
        return;
    }

    NSArray *exact = rules[@"exact"] ?: @[];
    NSArray *suffix = rules[@"suffix"] ?: @[];

    g_exactDomains = [NSSet setWithArray:exact];
    g_suffixDomains = [NSSet setWithArray:suffix];
    g_rulesLoaded = YES;

    GABLog(@"规则加载完成: 精确 %lu 条, 后缀 %lu 条",
          (unsigned long)g_exactDomains.count,
          (unsigned long)g_suffixDomains.count);
}

static BOOL isDomainBlocked(NSString *host) {
    if (!g_rulesLoaded) {
        loadRules();
    }
    if (!host || host.length == 0) return NO;

    NSString *lowerHost = [host lowercaseString];
    if ([g_exactDomains containsObject:lowerHost]) {
        return YES;
    }
    for (NSString *suffix in g_suffixDomains) {
        if ([lowerHost hasSuffix:suffix]) {
            if (lowerHost.length == suffix.length ||
                [lowerHost characterAtIndex:lowerHost.length - suffix.length - 1] == '.') {
                return YES;
            }
        }
    }
    return NO;
}

// 从 NSUserDefaults 一次性读取所有设置到内存缓存
// darwin 通知触发时才重读，平时零开销
static void vpnReloadSettingsCache(void) {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kGABDefaultsDomain];
    NSDictionary *all = [defaults dictionaryRepresentation];
    g_masterEnabledCache = all ? [all[kGABMasterSwitchKey] boolValue] : YES;
    g_appEnabledCache = [NSMutableSet set];
    for (NSString *k in all) {
        if ([k hasPrefix:kGABAppEnabledPrefix] && [all[k] boolValue]) {
            [g_appEnabledCache addObject:[k substringFromIndex:kGABAppEnabledPrefix.length]];
        }
    }
}

static BOOL isMasterEnabled(void) {
    return g_masterEnabledCache;
}

static BOOL isAppEnabled(NSString *bundleId) {
    if (!bundleId) return NO;
    // 用户没在 prefs 启用该 App = 不拦截（默认白名单为空）
    return [g_appEnabledCache containsObject:bundleId];
}

static NSString *currentAppBundleId(void) {
    return [[NSBundle mainBundle] bundleIdentifier];
}

static void settingsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    GABLog(@"收到设置变更通知，重载规则+刷新缓存");
    g_rulesLoaded = NO;
    loadRules();
    vpnReloadSettingsCache();
}

static void __attribute__((constructor)) initialize(void) {
    @autoreleasepool {
        GABLog(@"插件初始化");
        loadRules();
        vpnReloadSettingsCache();

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        settingsChangedCallback,
                                        (CFStringRef)kGABDarwinNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        GABLog(@"初始化完成, 当前 App: %@", currentAppBundleId());
    }
}

// Hook NSURLSessionTask resume：拦截所有 HTTP 请求
%hook NSURLSessionTask

- (void)resume {
    @try {
        // 1. 总开关检查（哈希表查 O(1)）
        if (!isMasterEnabled()) {
            %orig;
            return;
        }

        // 2. App 白名单检查（哈希表查 O(1)）
        NSString *bundleId = currentAppBundleId();
        if (!isAppEnabled(bundleId)) {
            %orig;
            return;
        }

        // 3. 提取 host
        NSURL *url = [self originalRequest] ? [[self originalRequest] URL] : [[self currentRequest] URL];
        if (!url) {
            %orig;
            return;
        }
        NSString *host = [url host];
        if (!host) {
            %orig;
            return;
        }

        // 4. 拦截广告域名
        if (isDomainBlocked(host)) {
            GABLog(@"拦截: %@ (App: %@)", host, bundleId);
            [self cancel];
            return;
        }
    } @catch (NSException *e) {
        GABLog(@"resume hook 异常: %@", e);
    }

    %orig;
}

%end

#pragma mark - v3.0 UI 层广告 SDK 拦截（基于 ad_hook 思路）

// 工具：判断当前 App 是否启用 + 总开关
static BOOL vptIsAdBlockingActive(void) {
    if (!g_masterEnabledCache) return NO;
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (!bid) return NO;
    return [g_appEnabledCache containsObject:bid];
}

// 工具：判断类名是否命中广告关键词
static BOOL vptIsAdViewController(NSString *className) {
    if (className.length == 0) return NO;
    static NSArray *keywords = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keywords = @[
            // 通用广告 VC
            @"AdViewController", @"InterstitialAdViewController",
            @"BannerAdViewController", @"RewardedAdViewController",
            @"SplashAdViewController", @"NativeAdViewController",
            // 字节穿山甲（Pangle/Bytedance）
            @"BUAd", @"PangleAd", @"CSJAd",
            // 腾讯优量汇
            @"GDTMobAd", @"GDTAd", @"TXAD",
            // Google AdMob
            @"GADAd", @"DFPAdView", @"GAMBannerAd",
            // 百度 Mobads
            @"BaiduMobAdSplash", @"BaiduAd",
            // 快手
            @"KsAd",
            // 小米
            @"MiAd",
        ];
    });
    for (NSString *k in keywords) {
        if ([className containsString:k]) {
            return YES;
        }
    }
    return NO;
}

static BOOL vptIsAdView(NSString *className) {
    if (className.length == 0) return NO;
    static NSArray *keywords = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keywords = @[
            // 通用
            @"AdView", @"BannerView", @"InterstitialView",
            @"RewardedAdView", @"SplashAdView", @"NativeAdView",
            @"FeedAdView", @"InsertAdView", @"BannerAd",
            // 字节穿山甲
            @"BUNativeAd", @"BUBannerAd", @"BUVideoAd",
            @"BUNativeExpress", @"CSJNativeAd",
            // 腾讯
            @"GDTMobBanner", @"GDTMobInterstitial", @"GDTVideoAd",
            // Google
            @"GADBannerView", @"GADInterstitial", @"GADNativeAd",
            // 百度
            @"BaiduAdSplashView", @"BaiduMobBanner",
            // 快手
            @"KsAdView", @"KsBannerView",
        ];
    });
    for (NSString *k in keywords) {
        if ([className containsString:k]) {
            return YES;
        }
    }
    return NO;
}

// 1) Hook 广告 ViewController：出现就立刻关闭
%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!vptIsAdBlockingActive()) return;
    NSString *className = NSStringFromClass([self class]);
    if (vptIsAdViewController(className)) {
        GABUILog(@"拦截广告VC: %@", className);
        // 延迟 0.1s 关闭（等内部 layout 完成）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self dismissViewControllerAnimated:NO completion:nil];
        });
    }
}

%end

// 2) Hook 广告 View：被加到父视图就隐藏 + 延迟移除
%hook UIView

- (void)didMoveToSuperview {
    %orig;
    if (!vptIsAdBlockingActive()) return;
    if (self.superview == nil) return; // 只在加入父视图时检查
    NSString *className = NSStringFromClass([self class]);
    if (vptIsAdView(className)) {
        GABUILog(@"拦截广告View: %@", className);
        self.hidden = YES;
        self.alpha = 0.0;
        self.userInteractionEnabled = NO;
        // 延迟 0.5s 移除（让 SDK 内部逻辑别 crash）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self removeFromSuperview];
        });
    }
}

%end

// 3) Hook 通用广告加载方法：拦截 SDK 主动调用
%hook NSObject

- (void)loadAd {
    if (vptIsAdBlockingActive()) {
        GABUILog(@"拦截 loadAd: %@", NSStringFromClass([self class]));
        return; // 不调用原实现
    }
    %orig;
}

- (void)loadAds {
    if (vptIsAdBlockingActive()) {
        GABUILog(@"拦截 loadAds: %@", NSStringFromClass([self class]));
        return;
    }
    %orig;
}

- (void)showAd {
    if (vptIsAdBlockingActive()) {
        GABUILog(@"拦截 showAd: %@", NSStringFromClass([self class]));
        return;
    }
    %orig;
}

- (void)showInterstitial {
    if (vptIsAdBlockingActive()) {
        GABUILog(@"拦截 showInterstitial: %@", NSStringFromClass([self class]));
        return;
    }
    %orig;
}

- (void)showRewardedAd {
    if (vptIsAdBlockingActive()) {
        GABUILog(@"拦截 showRewardedAd: %@（模拟已观看）", NSStringFromClass([self class]));
        // 激励视频特殊处理：模拟已看完，调用奖励回调
        SEL rewardSel = NSSelectorFromString(@"adDidEarnReward:");
        if ([self respondsToSelector:rewardSel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self performSelector:rewardSel withObject:nil];
            #pragma clang diagnostic pop
        }
        return;
    }
    %orig;
}

%end

// 4) Google AdMob SDK
%hook GADMobileAds

+ (instancetype)sharedInstance {
    if (vptIsAdBlockingActive()) {
        GABUILog(@"拦截 GADMobileAds sharedInstance");
    }
    return %orig;
}

- (void)startWithCompletionHandler:(void (^)(void))completionHandler {
    GABUILog(@"拦截 GADMobileAds start");
    if (completionHandler) {
        completionHandler();
    }
}

%end

// 5) 字节跳动穿山甲 SDK
%hook BUAdSDKManager

+ (void)setupWithAppId:(NSString *)appID {
    GABUILog(@"拦截 BUAdSDKManager setup: %@", appID);
    %orig; // 允许 SDK 初始化（不初始化会崩），但后续广告请求会被上面的 UI 拦截
}

%end

// 6) 腾讯优量汇 SDK
%hook GDTSDKConfig

+ (void)setupWithAppId:(NSString *)appId {
    GABUILog(@"拦截 GDTSDKConfig setup: %@", appId);
    %orig;
}

%end

// 7) 已加载 NSURLSessionTask hook 继续工作（v2.0 网络层拦截，无需重复）
