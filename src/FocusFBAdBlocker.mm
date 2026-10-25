#import "FocusFBAdBlocker.h"
#import "FocusFBPrefs.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <mach-o/dyld.h>
#include <algorithm>
#include <atomic>

@interface NSObject (FFBGraphQLModelSelectors)
- (nullable id)category;
- (nullable id)sponsoredData;
- (BOOL)isSponsored;
- (nullable id)storyBucketType;
@end

@protocol FFBRCTURLRequestDelegate <NSObject>
- (void)URLRequest:(id)requestToken didReceiveData:(NSData *)data;
- (void)URLRequest:(id)requestToken didCompleteWithError:(nullable NSError *)error;
@end

@interface NSObject (FFBRCTNetworkingSelectors)
- (nullable id)handlerForRequest:(NSURLRequest *)request;
- (nullable id)sendRequest:(NSURLRequest *)request withDelegate:(id)delegate;
@end

static std::atomic<uint64_t> gBlockedAdsCount{0};
static thread_local bool gInsideInternalJSONPass = false;

static char kCellHiddenByAdBlockKey;
static char kCellCountedByAdBlockKey;

typedef id (*FFBPandoInitIMP)(id, SEL, void *);
typedef id (*FFBJSONDataIMP)(id, SEL, NSData *, NSJSONReadingOptions, NSError * __autoreleasing *);
typedef id (*FFBRCTHandlerIMP)(id, SEL, NSURLRequest *);
typedef void (*FFBVoidIMP)(id, SEL);

static FFBPandoInitIMP  gOrigInitWithPandoTree = NULL;
static FFBPandoInitIMP  gOrigInitWithFBTree    = NULL;
static FFBJSONDataIMP   gOrigJSONWithData      = NULL;
static FFBRCTHandlerIMP gOrigRCTHandlerForReq  = NULL;
static FFBVoidIMP       gOrigCellLayout        = NULL;
static FFBVoidIMP       gOrigCellPrepareReuse  = NULL;

static BOOL gInstalledPandoHook    = NO;
static BOOL gInstalledFBTreeHook   = NO;
static BOOL gInstalledJSONHook     = NO;
static BOOL gInstalledRCTHook      = NO;
static BOOL gInstalledCellHooks    = NO;

NSUInteger FocusFBBlockedAdsCount(void) {
    return (NSUInteger)gBlockedAdsCount.load(std::memory_order_relaxed);
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper Runtime Sicuri (Thread-Safe, Zero Overhead NSMethodSignature)
// ─────────────────────────────────────────────────────────────────────────────

static BOOL FFBMethodReturnsObject(Class cls, SEL sel) {
    if (!cls || !sel) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    const char *enc = method_getTypeEncoding(m);
    return (enc != NULL && enc[0] == '@');
}

static BOOL FFBMethodReturnsBool(Class cls, SEL sel) {
    if (!cls || !sel) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    const char *enc = method_getTypeEncoding(m);
    return (enc != NULL && (enc[0] == 'B' || enc[0] == 'c'));
}

static BOOL FFBInstallMethodHook(Class cls, SEL sel, IMP newIMP, IMP *origOut) {
    if (!cls || !sel || !newIMP) return NO;
    Method resolved = class_getInstanceMethod(cls, sel);
    if (!resolved) return NO;
    IMP orig = method_getImplementation(resolved);
    const char *types = method_getTypeEncoding(resolved);
    if (!orig || !types || orig == newIMP) return NO;

    if (origOut && *origOut == NULL) {
        *origOut = orig;
    }

    unsigned int count = 0;
    Method *directList = class_copyMethodList(cls, &count);
    BOOL hasDirect = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(directList[i]) == sel) {
            hasDirect = YES;
            break;
        }
    }
    free(directList);

    if (hasDirect) {
        class_replaceMethod(cls, sel, newIMP, types);
    } else {
        if (!class_addMethod(cls, sel, newIMP, types)) {
            return NO;
        }
    }
    return YES;
}

// ─────────────────────────────────────────────────────────────────────────────
// Riconoscimento Unificato Nodi/Edge Pubblicitari JSON (Marketplace + Feed)
// ─────────────────────────────────────────────────────────────────────────────

static inline BOOL FFBHasNonNullValue(NSDictionary *dict, NSString *key) {
    id v = dict[key];
    return (v != nil && ![v isKindOfClass:NSNull.class]);
}

static BOOL FFBIsAdTypenameString(NSString *tn) {
    if (![tn isKindOfClass:NSString.class] || tn.length < 4) return NO;
    // Match sicuro: "Ad" o "Ads" seguito da lettera maiuscola (es. MarketplaceFeedAdStory,
    // MarketplaceSearchAdStory, MarketplaceAdsBlendedFeedUnit, AdsFeedUnit, StoryAdUnit)
    // oppure "Sponsored", così parole normali come "Address" o "Additional" non matchano mai.
    static NSRegularExpression *adTypeRegex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        adTypeRegex = [NSRegularExpression regularExpressionWithPattern:@"(?:Ads?[A-Z])|Sponsored|(?:StoryAd$)|(?:BannerAd$)"
                                                                options:0
                                                                  error:nil];
    });
    return [adTypeRegex firstMatchInString:tn options:0 range:NSMakeRange(0, tn.length)] != nil;
}

static BOOL FFBDictHasDirectAdMarkers(NSDictionary *d, BOOL blockAds, BOOL hideSuggested) {
    if (![d isKindOfClass:NSDictionary.class]) return NO;

    NSString *cat = d[@"category"];
    if ([cat isKindOfClass:NSString.class]) {
        if (blockAds &&
            ([cat isEqualToString:@"SPONSORED"] ||
             [cat isEqualToString:@"AD"] ||
             [cat isEqualToString:@"ADS"] ||
             [cat isEqualToString:@"MARKETPLACE_ADS"] ||
             [cat isEqualToString:@"SPONSORED_STORY"] ||
             [cat containsString:@"SPONSOR"])) {
            return YES;
        }
        if (hideSuggested &&
            ([cat isEqualToString:@"ENGAGEMENT"] ||
             [cat isEqualToString:@"ENGAGEMENT_QP"] ||
             [cat isEqualToString:@"PYMK"] ||
             [cat isEqualToString:@"PYMK_STORY"])) {
            return YES;
        }
    }

    if (!blockAds) return NO;

    NSString *tn = d[@"__typename"];
    if ([tn isKindOfClass:NSString.class] && FFBIsAdTypenameString(tn)) {
        return YES;
    }

    if (FFBHasNonNullValue(d, @"sponsored_data") ||
        FFBHasNonNullValue(d, @"ad_data") ||
        FFBHasNonNullValue(d, @"marketplace_ad_data") ||
        FFBHasNonNullValue(d, @"boosted_marketplace_listing") ||
        FFBHasNonNullValue(d, @"promoted_listing_info") ||
        FFBHasNonNullValue(d, @"ad_impression_client_token")) {
        return YES;
    }

    id adId = d[@"ad_id"];
    if ([adId isKindOfClass:NSString.class] && ((NSString *)adId).length > 0) {
        return YES;
    }

    id isSpons = d[@"is_sponsored"];
    if ([isSpons isKindOfClass:NSNumber.class] && [(NSNumber *)isSpons boolValue]) {
        return YES;
    }

    return NO;
}

static BOOL FFBIsSponsoredJSONItem(id item, BOOL blockAds, BOOL hideSuggested) {
    if (![item isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *dict = (NSDictionary *)item;

    // Non rimuovere mai un dizionario di metadati che è esso stesso sponsored_data,
    // ma rimuovi l'elemento dell'array (edge / unit / card) che lo contiene o il cui node/story/listing è sponsorizzato.
    if (FFBDictHasDirectAdMarkers(dict, blockAds, hideSuggested)) return YES;

    NSDictionary *node = [dict[@"node"] isKindOfClass:NSDictionary.class] ? dict[@"node"] : nil;
    if (node) {
        if (FFBDictHasDirectAdMarkers(node, blockAds, hideSuggested)) return YES;
        NSDictionary *nodeStory = [node[@"story"] isKindOfClass:NSDictionary.class] ? node[@"story"] : nil;
        if (nodeStory && FFBDictHasDirectAdMarkers(nodeStory, blockAds, hideSuggested)) return YES;
        NSDictionary *nodeListing = [node[@"listing"] isKindOfClass:NSDictionary.class] ? node[@"listing"] : nil;
        if (nodeListing && FFBDictHasDirectAdMarkers(nodeListing, blockAds, hideSuggested)) return YES;
    }

    NSDictionary *story = [dict[@"story"] isKindOfClass:NSDictionary.class] ? dict[@"story"] : nil;
    if (story && FFBDictHasDirectAdMarkers(story, blockAds, hideSuggested)) return YES;

    NSDictionary *listing = [dict[@"listing"] isKindOfClass:NSDictionary.class] ? dict[@"listing"] : nil;
    if (listing && FFBDictHasDirectAdMarkers(listing, blockAds, hideSuggested)) return YES;

    return NO;
}

// ─────────────────────────────────────────────────────────────────────────────
// MOTORE 1: React Native RCTNetworking (Marketplace Home, Search, Categorie, PDP)
// Facebook iOS v575-v585+ renderizza Marketplace in React Native + Hermes C++:
// Hermes fa JSON.parse() in C++, bypassando FBMemModelObject e NSJSONSerialization!
// Intercettando -[RCTNetworking handlerForRequest:] blocchiamo il 100% degli annunci
// Marketplace sia nelle query dedicate sia negli edge blended (inclusi stream \n).
// ─────────────────────────────────────────────────────────────────────────────

static NSString *FFBRCTExtractFriendlyName(NSURLRequest *request) {
    if (!request) return nil;
    NSString *hdr = [request valueForHTTPHeaderField:@"X-FB-Friendly-Name"];
    if (hdr.length > 0) return hdr;

    NSData *body = request.HTTPBody;
    if (!body || body.length == 0 || body.length > 512 * 1024) return nil;
    NSString *str = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    if (!str) return nil;

    NSRange r = [str rangeOfString:@"fb_api_req_friendly_name="];
    if (r.location != NSNotFound) {
        NSUInteger start = NSMaxRange(r);
        NSRange end = [str rangeOfString:@"&" options:0 range:NSMakeRange(start, str.length - start)];
        NSUInteger len = (end.location == NSNotFound ? str.length : end.location) - start;
        NSString *raw = [str substringWithRange:NSMakeRange(start, len)];
        raw = [raw stringByReplacingOccurrencesOfString:@"+" withString:@" "];
        return raw.stringByRemovingPercentEncoding ?: raw;
    }

    NSRange jr = [str rangeOfString:@"\"fb_api_req_friendly_name\":\""];
    if (jr.location != NSNotFound) {
        NSUInteger start = NSMaxRange(jr);
        NSRange end = [str rangeOfString:@"\"" options:0 range:NSMakeRange(start, str.length - start)];
        if (end.location != NSNotFound) {
            return [str substringWithRange:NSMakeRange(start, end.location - start)];
        }
    }
    return nil;
}

static BOOL FFBIsDedicatedAdQueryName(NSString *name) {
    if (name.length == 0) return NO;
    static NSSet<NSString *> *exactBlocked = nil;
    static NSRegularExpression *adQueryRegex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        exactBlocked = [NSSet setWithArray:@[
            @"MarketplaceHomeFeedAdsQueryRendererQuery",
            @"MarketplaceHomeFeedAdsPaginationQuery",
            @"MarketplaceHomeFeedBoostedListingAdsQuery",
            @"MarketplaceHomeFeedBoostedListingAdsPaginationQuery",
            @"MarketplacePDPBoostedListingAdsQuery",
            @"MarketplacePDPPersonalizedAdsQuery",
            @"MarketplaceProductDetailsPageRelatedAdsDetailQuery",
            @"MarketplaceSearchAdsQuery",
            @"MarketplaceSearchAdsPaginationQuery",
            @"MarketplaceCategoryFeedAdsQuery",
            @"MarketplaceBrowseAdsQuery"
        ]];
        // "Ad"/"Ads" seguito da lettera maiuscola o direttamente da "Query",
        // così "MarketplaceAddress..." o "MarketplaceAddListing..." non vengono mai toccati.
        adQueryRegex = [NSRegularExpression
            regularExpressionWithPattern:@"(?:^Marketplace\\w*Ads?(?:[A-Z]\\w*)?Query$)|(?:AdsQueryRendererQuery$)|(?:BoostedListingAds)|(?:RelatedAdsDetailQuery$)"
                                 options:0
                                   error:nil];
    });

    if ([exactBlocked containsObject:name]) return YES;
    return [adQueryRegex firstMatchInString:name options:0 range:NSMakeRange(0, name.length)] != nil;
}

static BOOL FFBShouldFilterRCTResponseForQuery(NSString *name) {
    if (name.length == 0) return NO;
    // Copre MarketplaceHomeFeed, MarketplaceSearch, MarketplaceCategory, MarketplacePDP,
    // MarketplaceBrowse, Commerce e qualsiasi altra query GraphQL su RCTNetworking.
    return ([name hasPrefix:@"Marketplace"] ||
            [name containsString:@"Marketplace"] ||
            [name containsString:@"Commerce"] ||
            [name containsString:@"Feed"] ||
            [name containsString:@"Search"]);
}

static NSUInteger FFBStripMutableJSONInPlace(id obj, BOOL blockAds, BOOL hideSuggested, NSUInteger depth) {
    if (!obj || depth > 24) return 0;
    NSUInteger removed = 0;

    if ([obj isKindOfClass:NSMutableArray.class]) {
        NSMutableArray *arr = (NSMutableArray *)obj;
        for (NSInteger i = (NSInteger)arr.count - 1; i >= 0; i--) {
            id item = arr[(NSUInteger)i];
            if (FFBIsSponsoredJSONItem(item, blockAds, hideSuggested)) {
                [arr removeObjectAtIndex:(NSUInteger)i];
                removed++;
            } else {
                removed += FFBStripMutableJSONInPlace(item, blockAds, hideSuggested, depth + 1);
            }
        }
    } else if ([obj isKindOfClass:NSMutableDictionary.class]) {
        NSMutableDictionary *dict = (NSMutableDictionary *)obj;
        NSArray *keys = [dict allKeys];
        for (id k in keys) {
            id val = dict[k];
            if ([val isKindOfClass:NSMutableArray.class] || [val isKindOfClass:NSMutableDictionary.class]) {
                removed += FFBStripMutableJSONInPlace(val, blockAds, hideSuggested, depth + 1);
            }
        }
    }
    return removed;
}

static NSData *FFBFilterRCTResponseData(NSData *data) {
    if (!data || data.length < 32 || data.length > 12 * 1024 * 1024) return data;

    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    if (!prefs.enabled) return data;
    BOOL blockAds = prefs.blockAllAds;
    BOOL hideSuggested = prefs.hideSuggestedClutter;
    if (!blockAds && !hideSuggested) return data;

    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!body || body.length == 0) return data;

    gInsideInternalJSONPass = true;
    NSData *resultData = data;

    @try {
        NSString *sep = [body containsString:@"\r\n"] ? @"\r\n" : @"\n";
        NSArray<NSString *> *parts = [body componentsSeparatedByString:sep];
        NSMutableArray<NSString *> *outParts = [NSMutableArray arrayWithCapacity:parts.count];
        NSUInteger totalRemoved = 0;

        for (NSString *part in parts) {
            NSString *trimmed = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (trimmed.length == 0) {
                [outParts addObject:part];
                continue;
            }
            NSData *partData = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
            if (!partData) {
                gInsideInternalJSONPass = false;
                return data;
            }
            id json = [NSJSONSerialization JSONObjectWithData:partData
                                                      options:NSJSONReadingMutableContainers
                                                        error:nil];
            if (!json) {
                // Non è JSON puro (es. multipart non standard): lascia invariato per sicurezza
                gInsideInternalJSONPass = false;
                return data;
            }

            NSUInteger removedHere = FFBStripMutableJSONInPlace(json, blockAds, hideSuggested, 0);
            if (removedHere == 0) {
                [outParts addObject:part];
                continue;
            }

            NSData *reserialized = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
            if (!reserialized) {
                gInsideInternalJSONPass = false;
                return data;
            }
            NSString *reStr = [[NSString alloc] initWithData:reserialized encoding:NSUTF8StringEncoding];
            if (!reStr) {
                gInsideInternalJSONPass = false;
                return data;
            }
            [outParts addObject:reStr];
            totalRemoved += removedHere;
        }

        if (totalRemoved > 0) {
            gBlockedAdsCount.fetch_add(totalRemoved, std::memory_order_relaxed);
            NSString *joined = [outParts componentsJoinedByString:sep];
            NSData *encoded = [joined dataUsingEncoding:NSUTF8StringEncoding];
            if (encoded.length > 0) {
                resultData = encoded;
            }
        }
    } @catch (__unused NSException *e) {
        resultData = data;
    }

    gInsideInternalJSONPass = false;
    return resultData;
}

@interface FFBBlockingRCTHandler : NSObject
+ (instancetype)shared;
@end

@implementation FFBBlockingRCTHandler

+ (instancetype)shared {
    static FFBBlockingRCTHandler *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[FFBBlockingRCTHandler alloc] init];
    });
    return instance;
}

+ (NSString *)moduleName {
    return @"FFBBlockingRCTHandler";
}

- (BOOL)canHandleRequest:(NSURLRequest *)request {
    return FFBIsDedicatedAdQueryName(FFBRCTExtractFriendlyName(request));
}

- (float)handlerPriority {
    return 0.0f;
}

- (id)sendRequest:(NSURLRequest *)request withDelegate:(id<FFBRCTURLRequestDelegate>)delegate {
    id token = [NSUUID UUID];
    NSError *err = [NSError errorWithDomain:NSURLErrorDomain
                                       code:NSURLErrorNotConnectedToInternet
                                   userInfo:@{NSLocalizedDescriptionKey: @"Blocked by FocusFB AdBlock"}];
    // Completamento asincrono così RCTNetworkTask registra prima il token senza race condition
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([delegate respondsToSelector:@selector(URLRequest:didCompleteWithError:)]) {
            [delegate URLRequest:token didCompleteWithError:err];
        }
    });
    return token;
}

- (void)cancelRequest:(__unused id)requestToken {
}

@end

static NSMutableSet *FFBLiveRCTDelegates(void) {
    static NSMutableSet *set = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSMutableSet set];
    });
    return set;
}

@interface FFBFilteringRCTDelegate : NSObject <FFBRCTURLRequestDelegate>
@property (nonatomic, strong) id realDelegate;
@property (nonatomic, strong) NSMutableData *buffer;
@end

@implementation FFBFilteringRCTDelegate

- (BOOL)respondsToSelector:(SEL)aSelector {
    return [super respondsToSelector:aSelector] || [self.realDelegate respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(__unused SEL)aSelector {
    return self.realDelegate;
}

- (void)URLRequest:(__unused id)requestToken didReceiveData:(NSData *)data {
    if (!data.length) return;
    @synchronized (self) {
        [self.buffer appendData:data];
    }
}

- (void)URLRequest:(id)requestToken didCompleteWithError:(NSError *)error {
    if (!error) {
        NSData *rawBody = nil;
        @synchronized (self) {
            rawBody = [self.buffer copy];
        }
        if (rawBody.length > 0) {
            NSData *filtered = FFBFilterRCTResponseData(rawBody);
            if (filtered.length > 0 && [self.realDelegate respondsToSelector:@selector(URLRequest:didReceiveData:)]) {
                [self.realDelegate URLRequest:requestToken didReceiveData:filtered];
            }
        }
    }
    if ([self.realDelegate respondsToSelector:@selector(URLRequest:didCompleteWithError:)]) {
        [self.realDelegate URLRequest:requestToken didCompleteWithError:error];
    }
    @synchronized (FFBLiveRCTDelegates()) {
        [FFBLiveRCTDelegates() removeObject:self];
    }
}

@end

@interface FFBFilteringRCTHandler : NSObject
@property (nonatomic, strong) id innerHandler;
@end

@implementation FFBFilteringRCTHandler

- (BOOL)respondsToSelector:(SEL)aSelector {
    return [super respondsToSelector:aSelector] || [self.innerHandler respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(__unused SEL)aSelector {
    return self.innerHandler;
}

- (id)sendRequest:(NSURLRequest *)request withDelegate:(id)delegate {
    FFBFilteringRCTDelegate *proxy = [[FFBFilteringRCTDelegate alloc] init];
    proxy.realDelegate = delegate;
    proxy.buffer = [NSMutableData data];
    @synchronized (FFBLiveRCTDelegates()) {
        [FFBLiveRCTDelegates() addObject:proxy];
    }
    return [self.innerHandler sendRequest:request withDelegate:proxy];
}

@end

static id FFBHook_RCTNetworking_handlerForRequest(id self, SEL _cmd, NSURLRequest *request) {
    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    if (prefs.enabled) {
        NSString *queryName = FFBRCTExtractFriendlyName(request);
        if (prefs.blockAllAds && FFBIsDedicatedAdQueryName(queryName)) {
            gBlockedAdsCount.fetch_add(1, std::memory_order_relaxed);
            return [FFBBlockingRCTHandler shared];
        }

        id origHandler = gOrigRCTHandlerForReq ? gOrigRCTHandlerForReq(self, _cmd, request) : nil;
        if (origHandler && (prefs.blockAllAds || prefs.hideSuggestedClutter) && FFBShouldFilterRCTResponseForQuery(queryName)) {
            FFBFilteringRCTHandler *wrapper = [[FFBFilteringRCTHandler alloc] init];
            wrapper.innerHandler = origHandler;
            return wrapper;
        }
        return origHandler;
    }
    return gOrigRCTHandlerForReq ? gOrigRCTHandlerForReq(self, _cmd, request) : nil;
}

// ─────────────────────────────────────────────────────────────────────────────
// MOTORE 2: Pando & FBTree C++ GraphQL Model Layer (FBMemModelObject)
// Rimuove gli annunci in News Feed, Gruppi, Storie, Reels e Video prima del dataSource
// ─────────────────────────────────────────────────────────────────────────────

static BOOL FFBIsThreadsPromoModel(id model, Class cls) {
    static NSArray<NSString *> *keys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[@"feedUnitType", @"feed_unit_type", @"unitType", @"inlineUnitType"];
    });

    for (NSString *key in keys) {
        SEL sel = NSSelectorFromString(key);
        if (FFBMethodReturnsObject(cls, sel)) {
            @try {
                id val = ((id (*)(id, SEL))objc_msgSend)(model, sel);
                if ([val isKindOfClass:NSString.class] &&
                    ([val isEqualToString:@"THREADS_IN_FEED_UNIT"] ||
                     [val isEqualToString:@"THREADS_IN_STORY_UNIT_MID_CARD"])) {
                    return YES;
                }
            } @catch (__unused NSException *e) {}
        }
        @try {
            id val = [model valueForKey:key];
            if ([val isKindOfClass:NSString.class] &&
                ([val isEqualToString:@"THREADS_IN_FEED_UNIT"] ||
                 [val isEqualToString:@"THREADS_IN_STORY_UNIT_MID_CARD"])) {
                return YES;
            }
        } @catch (__unused NSException *e) {}
    }
    return NO;
}

static BOOL FFBIsMarketplaceModelSponsoredViaKVC(id model) {
    static NSArray<NSString *> *nonNullAdKeys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        nonNullAdKeys = @[
            @"sponsored_data",
            @"sponsoredData",
            @"ad_data",
            @"adData",
            @"boosted_marketplace_listing",
            @"promoted_listing_info",
            @"marketplace_ad_data"
        ];
    });

    for (NSString *k in nonNullAdKeys) {
        @try {
            id v = [model valueForKey:k];
            if (v != nil && ![v isKindOfClass:NSNull.class]) {
                return YES;
            }
        } @catch (__unused NSException *e) {}
    }

    @try {
        id adId = [model valueForKey:@"ad_id"];
        if ([adId isKindOfClass:NSString.class] && ((NSString *)adId).length > 0) {
            return YES;
        }
    } @catch (__unused NSException *e) {}

    @try {
        id isSpons = [model valueForKey:@"is_sponsored"];
        if ([isSpons isKindOfClass:NSNumber.class] && [(NSNumber *)isSpons boolValue]) {
            return YES;
        }
    } @catch (__unused NSException *e) {}

    return NO;
}

static BOOL FFBShouldFilterGraphQLModel(id model) {
    if (!model) return NO;

    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    if (!prefs.enabled) return NO;

    BOOL blockAds = prefs.blockAllAds;
    BOOL hideSuggested = prefs.hideSuggestedClutter;
    BOOL hideStoriesReels = prefs.hideStoriesAndInlineReels;

    if (!blockAds && !hideSuggested && !hideStoriesReels) return NO;

    Class cls = object_getClass(model);
    NSString *clsName = NSStringFromClass(cls) ?: @"";

    // Non filtrare l'oggetto figlio *SponsoredData* stesso, così il post padre mantiene [story sponsoredData] != nil
    if ([clsName containsString:@"SponsoredData"] || [clsName hasSuffix:@"AdData"]) {
        return NO;
    }

    // 1. Controllo `category` (FBMemNewsFeedEdge, Marketplace Edges, Stories)
    SEL catSel = @selector(category);
    if (FFBMethodReturnsObject(cls, catSel)) {
        id rawCat = ((id (*)(id, SEL))objc_msgSend)(model, catSel);
        if ([rawCat isKindOfClass:NSString.class]) {
            NSString *cat = (NSString *)rawCat;
            if (blockAds &&
                ([cat isEqualToString:@"SPONSORED"] ||
                 [cat isEqualToString:@"AD"] ||
                 [cat isEqualToString:@"ADS"] ||
                 [cat isEqualToString:@"MARKETPLACE_ADS"] ||
                 [cat isEqualToString:@"SPONSORED_STORY"] ||
                 [cat containsString:@"SPONSOR"])) {
                gBlockedAdsCount.fetch_add(1, std::memory_order_relaxed);
                return YES;
            }
            if (hideSuggested &&
                ([cat isEqualToString:@"ENGAGEMENT"] ||
                 [cat isEqualToString:@"ENGAGEMENT_QP"] ||
                 [cat isEqualToString:@"PYMK"] ||
                 [cat isEqualToString:@"PYMK_STORY"])) {
                return YES;
            }
            if (hideStoriesReels &&
                ([cat isEqualToString:@"FB_SHORTS"] ||
                 [cat isEqualToString:@"MULTI_FB_STORIES_TRAY"])) {
                return YES;
            }
        }
    }

    // 2. Controllo `sponsoredData`, `isSponsored`, classi Ad e `storyBucketType`
    if (blockAds) {
        SEL sponsSel = @selector(sponsoredData);
        if (FFBMethodReturnsObject(cls, sponsSel)) {
            id sData = ((id (*)(id, SEL))objc_msgSend)(model, sponsSel);
            if (sData != nil && ![sData isKindOfClass:NSNull.class]) {
                gBlockedAdsCount.fetch_add(1, std::memory_order_relaxed);
                return YES;
            }
        }

        SEL isSponsSel = @selector(isSponsored);
        if (FFBMethodReturnsBool(cls, isSponsSel)) {
            BOOL flag = ((BOOL (*)(id, SEL))objc_msgSend)(model, isSponsSel);
            if (flag) {
                gBlockedAdsCount.fetch_add(1, std::memory_order_relaxed);
                return YES;
            }
        }

        if (FFBIsAdTypenameString(clsName) ||
            [clsName containsString:@"InstreamVideoAd"] ||
            [clsName containsString:@"VideoAdBreak"]) {
            gBlockedAdsCount.fetch_add(1, std::memory_order_relaxed);
            return YES;
        }

        SEL bucketSel = @selector(storyBucketType);
        if (FFBMethodReturnsObject(cls, bucketSel)) {
            id bucket = ((id (*)(id, SEL))objc_msgSend)(model, bucketSel);
            if ([bucket isKindOfClass:NSString.class]) {
                NSString *bStr = (NSString *)bucket;
                if ([bStr isEqualToString:@"ADS"] ||
                    [bStr isEqualToString:@"AD"] ||
                    [bStr isEqualToString:@"SPONSORED"] ||
                    [bStr isEqualToString:@"SPONSORED_STORY"] ||
                    [bStr containsString:@"SPONSOR"]) {
                    gBlockedAdsCount.fetch_add(1, std::memory_order_relaxed);
                    return YES;
                }
                if (hideSuggested && [bStr isEqualToString:@"PYMK_STORY"]) {
                    return YES;
                }
            }
        }

        if ([clsName containsString:@"Marketplace"] ||
            [clsName containsString:@"GroupCommerce"] ||
            [clsName containsString:@"CommerceProduct"]) {
            if (FFBIsMarketplaceModelSponsoredViaKVC(model)) {
                gBlockedAdsCount.fetch_add(1, std::memory_order_relaxed);
                return YES;
            }
        }
    }

    // 3. Rimozione unità suggerite (Gruppi, Pagine, PYMK, Promo Threads)
    if (hideSuggested) {
        if ([clsName containsString:@"GroupsYouShouldJoin"] ||
            [clsName containsString:@"PagesYouMayLike"] ||
            [clsName containsString:@"PeopleYouMayKnow"]) {
            return YES;
        }
        if ([clsName containsString:@"FeedUnit"] && FFBIsThreadsPromoModel(model, cls)) {
            return YES;
        }
    }

    if (hideStoriesReels && [clsName containsString:@"SingleBucketInlineViewer"]) {
        return YES;
    }

    return NO;
}

static id FFBHook_initWithFBPandoTree(id self, SEL _cmd, void *tree) {
    id model = gOrigInitWithPandoTree ? gOrigInitWithPandoTree(self, _cmd, tree) : nil;
    if (!model) return nil;
    return FFBShouldFilterGraphQLModel(model) ? nil : model;
}

static id FFBHook_initWithFBTree(id self, SEL _cmd, void *tree) {
    id model = gOrigInitWithFBTree ? gOrigInitWithFBTree(self, _cmd, tree) : nil;
    if (!model) return nil;
    return FFBShouldFilterGraphQLModel(model) ? nil : model;
}

// ─────────────────────────────────────────────────────────────────────────────
// MOTORE 3: NSJSONSerialization Pruner (Bloks / Relay Nativo fuori da RCTNetworking)
// ─────────────────────────────────────────────────────────────────────────────

static id FFBPruneAdsInJSONNode(id obj, BOOL mutableContainers, BOOL blockAds, BOOL hideSuggested, NSUInteger depth, BOOL *outChanged) {
    if (!obj || depth > 20) return obj;

    if ([obj isKindOfClass:NSArray.class]) {
        NSArray *arr = (NSArray *)obj;
        if (arr.count == 0) return obj;

        BOOL localChanged = NO;
        NSMutableArray *cleaned = nil;

        for (NSUInteger i = 0; i < arr.count; i++) {
            id item = arr[i];
            if (FFBIsSponsoredJSONItem(item, blockAds, hideSuggested)) {
                if (!localChanged) {
                    localChanged = YES;
                    cleaned = [NSMutableArray arrayWithCapacity:arr.count];
                    for (NSUInteger j = 0; j < i; j++) {
                        [cleaned addObject:arr[j]];
                    }
                }
                gBlockedAdsCount.fetch_add(1, std::memory_order_relaxed);
                continue;
            }

            BOOL childChanged = NO;
            id newItem = FFBPruneAdsInJSONNode(item, mutableContainers, blockAds, hideSuggested, depth + 1, &childChanged);
            if (childChanged && !localChanged) {
                localChanged = YES;
                cleaned = [NSMutableArray arrayWithCapacity:arr.count];
                for (NSUInteger j = 0; j < i; j++) {
                    [cleaned addObject:arr[j]];
                }
            }
            if (localChanged) {
                [cleaned addObject:(newItem ?: item)];
            }
        }

        if (localChanged) {
            if (outChanged) *outChanged = YES;
            return mutableContainers ? cleaned : [cleaned copy];
        }
        return obj;
    }

    if ([obj isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict = (NSDictionary *)obj;
        if (dict.count == 0) return obj;

        BOOL localChanged = NO;
        NSMutableDictionary *mutDict = nil;

        for (id key in dict) {
            id val = dict[key];
            if (![val isKindOfClass:NSArray.class] && ![val isKindOfClass:NSDictionary.class]) {
                continue;
            }
            BOOL childChanged = NO;
            id newVal = FFBPruneAdsInJSONNode(val, mutableContainers, blockAds, hideSuggested, depth + 1, &childChanged);
            if (childChanged) {
                if (!localChanged) {
                    localChanged = YES;
                    mutDict = [dict mutableCopy];
                }
                mutDict[key] = newVal;
            }
        }

        if (localChanged) {
            if (outChanged) *outChanged = YES;
            return mutableContainers ? mutDict : [mutDict copy];
        }
        return obj;
    }

    return obj;
}

static inline BOOL FFBBytesContainASCII(const uint8_t *buf, size_t bufLen, const char *pat, size_t patLen) {
    const uint8_t *p = reinterpret_cast<const uint8_t *>(pat);
    return std::search(buf, buf + bufLen, p, p + patLen) != (buf + bufLen);
}

static BOOL FFBDataMayContainAdsTokens(NSData *data) {
    const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
    size_t len = (size_t)data.length;
    if (!bytes || len < 48) return NO;

    if (FFBBytesContainASCII(bytes, len, "sponsored", 9)) return YES;
    if (FFBBytesContainASCII(bytes, len, "SPONSORED", 9)) return YES;
    if (FFBBytesContainASCII(bytes, len, "Sponsored", 9)) return YES;
    if (FFBBytesContainASCII(bytes, len, "ad_data", 7))   return YES;
    if (FFBBytesContainASCII(bytes, len, "\"ad_id\"", 7)) return YES;
    if (FFBBytesContainASCII(bytes, len, "AdStory", 7))   return YES;
    if (FFBBytesContainASCII(bytes, len, "AdsFeed", 7))   return YES;
    if (FFBBytesContainASCII(bytes, len, "AdUnit", 6))    return YES;
    if (FFBBytesContainASCII(bytes, len, "BannerAd", 8))  return YES;
    return NO;
}

static id FFBHook_JSONObjectWithData(id self,
                                     SEL _cmd,
                                     NSData *data,
                                     NSJSONReadingOptions opt,
                                     NSError * __autoreleasing *error) {
    id parsed = gOrigJSONWithData ? gOrigJSONWithData(self, _cmd, data, opt, error) : nil;
    if (!parsed || !data || gInsideInternalJSONPass) return parsed;

    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    if (!prefs.enabled) return parsed;
    BOOL blockAds = prefs.blockAllAds;
    BOOL hideSuggested = prefs.hideSuggestedClutter;
    if (!blockAds && !hideSuggested) return parsed;
    if (data.length < 64 || data.length > 8 * 1024 * 1024) return parsed;
    if (!FFBDataMayContainAdsTokens(data)) return parsed;

    @try {
        BOOL changed = NO;
        BOOL wantMutable = ((opt & NSJSONReadingMutableContainers) != 0);
        return FFBPruneAdsInJSONNode(parsed, wantMutable, blockAds, hideSuggested, 0, &changed);
    } @catch (__unused NSException *e) {
        return parsed;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MOTORE 4: Rete di Sicurezza UI su Celle già in Cache (ComponentKit / Bloks / RN)
// ─────────────────────────────────────────────────────────────────────────────

static BOOL FFBTextIsStandaloneSponsoredBadge(NSString *raw) {
    if (![raw isKindOfClass:NSString.class] || raw.length < 6 || raw.length > 160) return NO;
    NSCharacterSet *sep = [NSCharacterSet characterSetWithCharactersInString:@"\n\r•·|,"];
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];

    for (NSString *segment in [raw componentsSeparatedByCharactersInSet:sep]) {
        NSString *t = [[segment stringByTrimmingCharactersInSet:ws] lowercaseString];
        if (t.length < 6 || t.length > 40) continue;
        if ([t isEqualToString:@"sponsorizzato"] ||
            [t isEqualToString:@"sponsored"] ||
            [t isEqualToString:@"sponsorizzato dal venditore"] ||
            [t isEqualToString:@"sponsored by seller"] ||
            [t isEqualToString:@"inserzione sponsorizzata"] ||
            [t isEqualToString:@"annuncio sponsorizzato"] ||
            [t isEqualToString:@"partnership pubblicitaria"] ||
            [t isEqualToString:@"paid partnership"] ||
            [t isEqualToString:@"sponsorisé"] ||
            [t isEqualToString:@"publicidad"] ||
            [t isEqualToString:@"gesponsert"]) {
            return YES;
        }
    }
    return NO;
}

static BOOL FFBSubtreeHasSponsoredDisclosure(UIView *view, NSUInteger depth) {
    if (!view || depth > 7) return NO;

    if ([view isKindOfClass:UILabel.class]) {
        if (FFBTextIsStandaloneSponsoredBadge(((UILabel *)view).text)) return YES;
    }
    NSString *axLbl = view.accessibilityLabel;
    if (axLbl.length > 0 && FFBTextIsStandaloneSponsoredBadge(axLbl)) {
        return YES;
    }
    NSString *axId = view.accessibilityIdentifier;
    if (axId.length > 0) {
        NSString *lowerId = axId.lowercaseString;
        if ([lowerId containsString:@"sponsored_label"] ||
            [lowerId containsString:@"marketplace_ad"] ||
            [lowerId isEqualToString:@"ad_badge"]) {
            return YES;
        }
    }

    for (UIView *sub in view.subviews) {
        if (FFBSubtreeHasSponsoredDisclosure(sub, depth + 1)) return YES;
    }
    return NO;
}

static void FFBResetAdHiddenCellIfNeeded(UICollectionViewCell *cell) {
    if ([objc_getAssociatedObject(cell, &kCellHiddenByAdBlockKey) boolValue]) {
        cell.contentView.hidden = NO;
        cell.alpha = 1.0;
        cell.userInteractionEnabled = YES;
        objc_setAssociatedObject(cell, &kCellHiddenByAdBlockKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, &kCellCountedByAdBlockKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void FFBHook_Cell_prepareForReuse(id self, SEL _cmd) {
    if (gOrigCellPrepareReuse) gOrigCellPrepareReuse(self, _cmd);
    FFBResetAdHiddenCellIfNeeded((UICollectionViewCell *)self);
}

static void FFBHook_Cell_layoutSubviews(id self, SEL _cmd) {
    if (gOrigCellLayout) gOrigCellLayout(self, _cmd);
    if (!NSThread.isMainThread) return;

    UICollectionViewCell *cell = (UICollectionViewCell *)self;
    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    if (!prefs.enabled || !prefs.blockAllAds) {
        FFBResetAdHiddenCellIfNeeded(cell);
        return;
    }

    UIView *parent = cell.superview;
    if (!parent) return;
    NSString *parentCls = NSStringFromClass(object_getClass(parent)) ?: @"";
    NSString *cellCls = NSStringFromClass(object_getClass(cell)) ?: @"";
    if (![parentCls hasPrefix:@"FB"] && ![parentCls hasPrefix:@"CK"] &&
        ![parentCls hasPrefix:@"RCT"] && ![parentCls hasPrefix:@"BK"] &&
        ![cellCls hasPrefix:@"FB"] && ![cellCls hasPrefix:@"CK"] &&
        ![cellCls hasPrefix:@"RCT"] && ![cellCls hasPrefix:@"BK"]) {
        return;
    }

    if (FFBSubtreeHasSponsoredDisclosure(cell.contentView, 0)) {
        cell.contentView.hidden = YES;
        cell.alpha = 0.0;
        cell.userInteractionEnabled = NO;
        objc_setAssociatedObject(cell, &kCellHiddenByAdBlockKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (![objc_getAssociatedObject(cell, &kCellCountedByAdBlockKey) boolValue]) {
            objc_setAssociatedObject(cell, &kCellCountedByAdBlockKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            gBlockedAdsCount.fetch_add(1, std::memory_order_relaxed);
        }
    } else {
        FFBResetAdHiddenCellIfNeeded(cell);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Installazione Hook AdBlock (Immediata + Dyld Lazy-Loaded Framework Listener)
// FBReactNativeProductsFramework (RCTNetworking) e FBSharedFramework (Pando)
// vengono agganciati nell'istante esatto in cui dyld li carica in memoria!
// ─────────────────────────────────────────────────────────────────────────────

static void FFBInstallAvailableAdHooksNow(void) {
    if (!gInstalledRCTHook) {
        Class rctNetCls = objc_getClass("RCTNetworking");
        if (rctNetCls) {
            SEL reqSel = @selector(handlerForRequest:);
            if ([rctNetCls instancesRespondToSelector:reqSel]) {
                gInstalledRCTHook = FFBInstallMethodHook(rctNetCls,
                                                         reqSel,
                                                         (IMP)FFBHook_RCTNetworking_handlerForRequest,
                                                         (IMP *)&gOrigRCTHandlerForReq);
            }
        }
    }

    Class memModelCls = objc_getClass("FBMemModelObject");
    if (memModelCls) {
        SEL pandoSel = NSSelectorFromString(@"initWithFBPandoTree:");
        if (!gInstalledPandoHook && [memModelCls instancesRespondToSelector:pandoSel]) {
            gInstalledPandoHook = FFBInstallMethodHook(memModelCls,
                                                       pandoSel,
                                                       (IMP)FFBHook_initWithFBPandoTree,
                                                       (IMP *)&gOrigInitWithPandoTree);
        }
        SEL fbTreeSel = NSSelectorFromString(@"initWithFBTree:");
        if (!gInstalledFBTreeHook && [memModelCls instancesRespondToSelector:fbTreeSel]) {
            gInstalledFBTreeHook = FFBInstallMethodHook(memModelCls,
                                                        fbTreeSel,
                                                        (IMP)FFBHook_initWithFBTree,
                                                        (IMP *)&gOrigInitWithFBTree);
        }
    }

    if (!gInstalledJSONHook) {
        Class jsonMetaCls = object_getClass(NSJSONSerialization.class);
        if (jsonMetaCls) {
            gInstalledJSONHook = FFBInstallMethodHook(jsonMetaCls,
                                                      @selector(JSONObjectWithData:options:error:),
                                                      (IMP)FFBHook_JSONObjectWithData,
                                                      (IMP *)&gOrigJSONWithData);
        }
    }

    if (!gInstalledCellHooks) {
        BOOL ok1 = FFBInstallMethodHook(UICollectionViewCell.class,
                                        @selector(layoutSubviews),
                                        (IMP)FFBHook_Cell_layoutSubviews,
                                        (IMP *)&gOrigCellLayout);
        BOOL ok2 = FFBInstallMethodHook(UICollectionViewCell.class,
                                        @selector(prepareForReuse),
                                        (IMP)FFBHook_Cell_prepareForReuse,
                                        (IMP *)&gOrigCellPrepareReuse);
        gInstalledCellHooks = (ok1 && ok2);
    }
}

static void FFBAdBlockDyldImageAdded(__unused const struct mach_header *mh, __unused intptr_t vmaddr_slide) {
    if (gInstalledRCTHook && gInstalledPandoHook && gInstalledFBTreeHook) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        FFBInstallAvailableAdHooksNow();
    });
}

void FocusFBInstallAdBlocker(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FFBInstallAvailableAdHooksNow();
        // Fondamentale: aggancia automaticamente FBReactNativeProductsFramework (RCTNetworking)
        // non appena Marketplace viene caricato, anche minuti dopo l'avvio dell'app!
        _dyld_register_func_for_add_image(FFBAdBlockDyldImageAdded);
    });
}
