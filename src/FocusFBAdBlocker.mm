#import "FocusFBAdBlocker.h"
#import "FocusFBPrefs.h"
#import "FocusFBStoriesManager.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <algorithm>
#include <atomic>

@interface NSObject (FFBGraphQLModelSelectors)
- (nullable id)category;
- (nullable id)sponsoredData;
- (BOOL)isSponsored;
- (nullable id)storyBucketType;
@end

@protocol FFBRCTURLRequestDelegate <NSObject>
- (void)URLRequest:(id)requestToken didReceiveResponse:(NSURLResponse *)response;
- (void)URLRequest:(id)requestToken didReceiveData:(NSData *)data;
- (void)URLRequest:(id)requestToken didCompleteWithError:(nullable NSError *)error;
@end

@interface NSObject (FFBRCTNetworkingSelectors)
- (nullable id)handlerForRequest:(NSURLRequest *)request;
- (nullable id)sendRequest:(NSURLRequest *)request withDelegate:(id)delegate;
@end

static std::atomic<uint64_t> gBlockedAdsCount{0};
static std::atomic<bool> gAdBlockerReady{false};
static thread_local bool gInsideInternalJSONPass = false;

// IMPORTANTE: per i selettori della famiglia -init* usiamo void* grezzi così Clang ARC
// rispetta esattamente la convenzione ns_consumed (self +1) -> ns_returns_retained (+1)!
typedef void *(*FFBPandoRawInitIMP)(void *, SEL, void *);
typedef id (*FFBJSONDataIMP)(id, SEL, NSData *, NSJSONReadingOptions, NSError * __autoreleasing *);
typedef id (*FFBRCTHandlerIMP)(id, SEL, NSURLRequest *);

static FFBPandoRawInitIMP gOrigInitWithPandoTree = NULL;
static FFBPandoRawInitIMP gOrigInitWithFBTree    = NULL;
static FFBJSONDataIMP      gOrigJSONWithData      = NULL;
static FFBRCTHandlerIMP    gOrigRCTHandlerForReq  = NULL;

static BOOL gInstalledPandoHook  = NO;
static BOOL gInstalledFBTreeHook = NO;
static BOOL gInstalledJSONHook   = NO;
static BOOL gInstalledRCTHook    = NO;

struct FFBFilterFlags {
    BOOL blockAds;
    BOOL hidePYMK;
    BOOL hideReelsCarousel;
    BOOL hideSuggested;
    BOOL hideStoriesTray;

    bool anyActive() const noexcept {
        return blockAds || hidePYMK || hideReelsCarousel || hideSuggested || hideStoriesTray;
    }
    bool anyJSONActive() const noexcept {
        return blockAds || hidePYMK || hideReelsCarousel || hideSuggested;
    }
};

static inline FFBFilterFlags FFBReadCurrentFilterFlags(void) {
    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    if (!prefs.enabled) {
        return FFBFilterFlags{NO, NO, NO, NO, NO};
    }
    return FFBFilterFlags{
        prefs.blockAllAds,
        prefs.hidePeopleYouMayKnow,
        prefs.hideReelsCarousel,
        prefs.hideSuggestedClutter,
        prefs.hideStoriesTray
    };
}

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
// Riconoscimento Unificato Nodi/Edge Pubblicitari, PYMK & Reels Carousel
// ─────────────────────────────────────────────────────────────────────────────

static inline BOOL FFBHasNonNullValue(NSDictionary *dict, NSString *key) {
    id v = dict[key];
    return (v != nil && ![v isKindOfClass:NSNull.class]);
}

static BOOL FFBIsAdTypenameString(NSString *tn) {
    if (![tn isKindOfClass:NSString.class] || tn.length < 4) return NO;
    static NSRegularExpression *adTypeRegex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        adTypeRegex = [NSRegularExpression
            regularExpressionWithPattern:@"(?:Ads?[A-Z])|Sponsored|(?:StoryAd$)|(?:BannerAd$)"
                                 options:0
                                   error:nil];
    });
    return [adTypeRegex firstMatchInString:tn options:0 range:NSMakeRange(0, tn.length)] != nil;
}

static BOOL FFBIsPYMKTypenameString(NSString *tn) {
    if (![tn isKindOfClass:NSString.class] || tn.length < 4) return NO;
    return ([tn rangeOfString:@"PeopleYouMayKnow" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [tn rangeOfString:@"PYMK" options:0].location != NSNotFound ||
            [tn rangeOfString:@"FriendingPossibilities" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [tn rangeOfString:@"FriendSuggestions" options:NSCaseInsensitiveSearch].location != NSNotFound);
}

static BOOL FFBIsReelsCarouselTypenameString(NSString *tn) {
    if (![tn isKindOfClass:NSString.class] || tn.length < 6) return NO;
    // Matcha solo unità/caroselli nel Feed (es. FbShortsFeedUnit, ReelsFeedUnit, ClipsHomeUnit),
    // mai il singolo oggetto video riprodotto quando apri intenzionalmente un video.
    return ([tn rangeOfString:@"ShortsFeedUnit" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [tn rangeOfString:@"ShortsInFeed" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [tn rangeOfString:@"ReelsFeedUnit" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [tn rangeOfString:@"ReelsTray" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [tn rangeOfString:@"ReelsHScroll" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [tn rangeOfString:@"ClipsHomeUnit" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [tn rangeOfString:@"ShortFormVideoFeedUnit" options:NSCaseInsensitiveSearch].location != NSNotFound);
}

static BOOL FFBIsSuggestedTypenameString(NSString *tn) {
    if (![tn isKindOfClass:NSString.class] || tn.length < 6) return NO;
    return ([tn rangeOfString:@"GroupsYouShouldJoin" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [tn rangeOfString:@"PagesYouMayLike" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [tn rangeOfString:@"ThreadsInFeed" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [tn rangeOfString:@"SingleBucketInlineViewer" options:NSCaseInsensitiveSearch].location != NSNotFound);
}

static BOOL FFBDictHasDirectFilterMarkers(NSDictionary *d, const FFBFilterFlags &flags, BOOL *outIsAd) {
    if (![d isKindOfClass:NSDictionary.class]) return NO;

    NSString *cat = d[@"category"];
    if ([cat isKindOfClass:NSString.class]) {
        if (flags.blockAds &&
            ([cat isEqualToString:@"SPONSORED"] ||
             [cat isEqualToString:@"AD"] ||
             [cat isEqualToString:@"ADS"] ||
             [cat isEqualToString:@"MARKETPLACE_ADS"] ||
             [cat isEqualToString:@"SPONSORED_STORY"] ||
             [cat containsString:@"SPONSOR"])) {
            if (outIsAd) *outIsAd = YES;
            return YES;
        }
        if (flags.hidePYMK &&
            ([cat isEqualToString:@"PYMK"] ||
             [cat isEqualToString:@"PYMK_STORY"] ||
             [cat isEqualToString:@"FRIENDING"])) {
            return YES;
        }
        if (flags.hideReelsCarousel &&
            ([cat isEqualToString:@"FB_SHORTS"] ||
             [cat isEqualToString:@"FB_SHORTS_FALLBACK"] ||
             [cat isEqualToString:@"SHORT_FORM_VIDEO"] ||
             [cat containsString:@"FB_SHORTS"])) {
            return YES;
        }
        if (flags.hideSuggested &&
            ([cat isEqualToString:@"ENGAGEMENT"] ||
             [cat isEqualToString:@"ENGAGEMENT_QP"] ||
             [cat isEqualToString:@"RECOMMENDATION"])) {
            return YES;
        }
    }

    NSString *tn = d[@"__typename"];
    if ([tn isKindOfClass:NSString.class]) {
        if (flags.blockAds && FFBIsAdTypenameString(tn)) {
            if (outIsAd) *outIsAd = YES;
            return YES;
        }
        if (flags.hidePYMK && FFBIsPYMKTypenameString(tn)) {
            return YES;
        }
        if (flags.hideReelsCarousel && FFBIsReelsCarouselTypenameString(tn)) {
            return YES;
        }
        if (flags.hideSuggested && FFBIsSuggestedTypenameString(tn)) {
            return YES;
        }
    }

    if (!flags.blockAds) return NO;

    if (FFBHasNonNullValue(d, @"sponsored_data") ||
        FFBHasNonNullValue(d, @"ad_data") ||
        FFBHasNonNullValue(d, @"marketplace_ad_data") ||
        FFBHasNonNullValue(d, @"boosted_marketplace_listing") ||
        FFBHasNonNullValue(d, @"promoted_listing_info") ||
        FFBHasNonNullValue(d, @"ad_impression_client_token")) {
        if (outIsAd) *outIsAd = YES;
        return YES;
    }

    id adId = d[@"ad_id"];
    if ([adId isKindOfClass:NSString.class] && ((NSString *)adId).length > 0) {
        if (outIsAd) *outIsAd = YES;
        return YES;
    }

    id isSpons = d[@"is_sponsored"];
    if ([isSpons isKindOfClass:NSNumber.class] && [(NSNumber *)isSpons boolValue]) {
        if (outIsAd) *outIsAd = YES;
        return YES;
    }

    return NO;
}

static BOOL FFBShouldDropJSONItem(id item, const FFBFilterFlags &flags, BOOL *outIsAd) {
    if (![item isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *dict = (NSDictionary *)item;

    if (FFBDictHasDirectFilterMarkers(dict, flags, outIsAd)) return YES;

    NSDictionary *node = [dict[@"node"] isKindOfClass:NSDictionary.class] ? dict[@"node"] : nil;
    if (node) {
        if (FFBDictHasDirectFilterMarkers(node, flags, outIsAd)) return YES;
        NSDictionary *nodeStory = [node[@"story"] isKindOfClass:NSDictionary.class] ? node[@"story"] : nil;
        if (nodeStory && FFBDictHasDirectFilterMarkers(nodeStory, flags, outIsAd)) return YES;
        NSDictionary *nodeListing = [node[@"listing"] isKindOfClass:NSDictionary.class] ? node[@"listing"] : nil;
        if (nodeListing && FFBDictHasDirectFilterMarkers(nodeListing, flags, outIsAd)) return YES;
    }

    NSDictionary *story = [dict[@"story"] isKindOfClass:NSDictionary.class] ? dict[@"story"] : nil;
    if (story && FFBDictHasDirectFilterMarkers(story, flags, outIsAd)) return YES;

    NSDictionary *listing = [dict[@"listing"] isKindOfClass:NSDictionary.class] ? dict[@"listing"] : nil;
    if (listing && FFBDictHasDirectFilterMarkers(listing, flags, outIsAd)) return YES;

    return NO;
}

static inline BOOL FFBBytesContainASCII(const uint8_t *buf, size_t bufLen, const char *pat, size_t patLen) {
    const uint8_t *p = reinterpret_cast<const uint8_t *>(pat);
    return std::search(buf, buf + bufLen, p, p + patLen) != (buf + bufLen);
}

// Fast-path C++ sub-millisecondo: evita conversione NSString e NSJSONSerialization
// sulle pagine pulite di Marketplace durante lo scroll veloce!
static BOOL FFBDataMayContainFilterableTokens(NSData *data, const FFBFilterFlags &flags) {
    const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
    size_t len = (size_t)data.length;
    if (!bytes || len < 48) return NO;

    if (flags.blockAds) {
        if (FFBBytesContainASCII(bytes, len, "sponsored", 9)) return YES;
        if (FFBBytesContainASCII(bytes, len, "SPONSORED", 9)) return YES;
        if (FFBBytesContainASCII(bytes, len, "Sponsored", 9)) return YES;
        if (FFBBytesContainASCII(bytes, len, "ad_data", 7))   return YES;
        if (FFBBytesContainASCII(bytes, len, "\"ad_id\"", 7)) return YES;
        if (FFBBytesContainASCII(bytes, len, "boosted_", 8))  return YES;
        if (FFBBytesContainASCII(bytes, len, "promoted_", 9)) return YES;
        if (FFBBytesContainASCII(bytes, len, "AdStory", 7))   return YES;
        if (FFBBytesContainASCII(bytes, len, "AdsFeed", 7))   return YES;
        if (FFBBytesContainASCII(bytes, len, "AdUnit", 6))    return YES;
        if (FFBBytesContainASCII(bytes, len, "BannerAd", 8))  return YES;
    }
    if (flags.hidePYMK) {
        if (FFBBytesContainASCII(bytes, len, "PYMK", 4))             return YES;
        if (FFBBytesContainASCII(bytes, len, "PeopleYouMayKnow", 16)) return YES;
        if (FFBBytesContainASCII(bytes, len, "FriendingPossib", 15))  return YES;
    }
    if (flags.hideReelsCarousel) {
        if (FFBBytesContainASCII(bytes, len, "FB_SHORTS", 9))      return YES;
        if (FFBBytesContainASCII(bytes, len, "ShortsFeedUnit", 14)) return YES;
        if (FFBBytesContainASCII(bytes, len, "ReelsFeedUnit", 13))  return YES;
    }
    if (flags.hideSuggested) {
        if (FFBBytesContainASCII(bytes, len, "ENGAGEMENT", 10))         return YES;
        if (FFBBytesContainASCII(bytes, len, "GroupsYouShouldJoin", 19)) return YES;
        if (FFBBytesContainASCII(bytes, len, "PagesYouMayLike", 15))     return YES;
        if (FFBBytesContainASCII(bytes, len, "ThreadsInFeed", 13))       return YES;
    }
    return NO;
}

// ─────────────────────────────────────────────────────────────────────────────
// MOTORE 1: React Native RCTNetworking (Marketplace Home, Search, Categorie, PDP)
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
    return ([name hasPrefix:@"Marketplace"] ||
            [name containsString:@"Marketplace"] ||
            [name containsString:@"Commerce"] ||
            [name containsString:@"Feed"] ||
            [name containsString:@"Search"]);
}

static NSUInteger FFBStripMutableJSONInPlace(id obj, const FFBFilterFlags &flags, NSUInteger depth, NSUInteger *outAdsCount) {
    if (!obj || depth > 24) return 0;
    NSUInteger removed = 0;

    if ([obj isKindOfClass:NSMutableArray.class]) {
        NSMutableArray *arr = (NSMutableArray *)obj;
        for (NSInteger i = (NSInteger)arr.count - 1; i >= 0; i--) {
            id item = arr[(NSUInteger)i];
            BOOL isAd = NO;
            if (FFBShouldDropJSONItem(item, flags, &isAd)) {
                [arr removeObjectAtIndex:(NSUInteger)i];
                removed++;
                if (isAd && outAdsCount) (*outAdsCount)++;
            } else {
                removed += FFBStripMutableJSONInPlace(item, flags, depth + 1, outAdsCount);
            }
        }
    } else if ([obj isKindOfClass:NSMutableDictionary.class]) {
        NSMutableDictionary *dict = (NSMutableDictionary *)obj;
        NSArray *keys = [dict allKeys];
        for (id k in keys) {
            id val = dict[k];
            if ([val isKindOfClass:NSMutableArray.class] || [val isKindOfClass:NSMutableDictionary.class]) {
                removed += FFBStripMutableJSONInPlace(val, flags, depth + 1, outAdsCount);
            }
        }
    }
    return removed;
}

static NSData *FFBFilterRCTResponseData(NSData *data) {
    if (!data || data.length < 48 || data.length > 12 * 1024 * 1024) return data;

    FFBFilterFlags flags = FFBReadCurrentFilterFlags();
    if (!flags.anyJSONActive()) return data;

    // Fast-path byte-scan: se la pagina non contiene alcun token sponsorizzato/PYMK, restituisci subito i byte originali!
    if (!FFBDataMayContainFilterableTokens(data, flags)) {
        return data;
    }

    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!body || body.length == 0) return data;

    gInsideInternalJSONPass = true;
    NSData *resultData = data;

    @try {
        NSString *sep = [body containsString:@"\r\n"] ? @"\r\n" : @"\n";
        NSArray<NSString *> *parts = [body componentsSeparatedByString:sep];
        NSMutableArray<NSString *> *outParts = [NSMutableArray arrayWithCapacity:parts.count];
        NSUInteger totalRemoved = 0;
        NSUInteger totalAds = 0;

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
            if (!FFBDataMayContainFilterableTokens(partData, flags)) {
                [outParts addObject:part];
                continue;
            }
            id json = [NSJSONSerialization JSONObjectWithData:partData
                                                      options:NSJSONReadingMutableContainers
                                                        error:nil];
            if (!json) {
                gInsideInternalJSONPass = false;
                return data;
            }

            NSUInteger removedHere = FFBStripMutableJSONInPlace(json, flags, 0, &totalAds);
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
            if (totalAds > 0) {
                gBlockedAdsCount.fetch_add(totalAds, std::memory_order_relaxed);
            }
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
@property (nonatomic, assign) BOOL returnEmptyGraphQLJSON;
+ (instancetype)sharedAdBlocker;
+ (instancetype)sharedSilentSuccess;
@end

@implementation FFBBlockingRCTHandler

+ (instancetype)sharedAdBlocker {
    static FFBBlockingRCTHandler *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[FFBBlockingRCTHandler alloc] init];
        instance.returnEmptyGraphQLJSON = NO;
    });
    return instance;
}

+ (instancetype)sharedSilentSuccess {
    static FFBBlockingRCTHandler *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[FFBBlockingRCTHandler alloc] init];
        instance.returnEmptyGraphQLJSON = YES;
    });
    return instance;
}

+ (NSString *)moduleName {
    return @"FFBBlockingRCTHandler";
}

- (BOOL)canHandleRequest:(NSURLRequest *)request {
    return FFBIsDedicatedAdQueryName(FFBRCTExtractFriendlyName(request)) ||
           FocusFBIsStorySeenNetworkRequest(request);
}

- (float)handlerPriority {
    return 0.0f;
}

- (id)sendRequest:(NSURLRequest *)request withDelegate:(id<FFBRCTURLRequestDelegate>)delegate {
    id token = [NSUUID UUID];
    BOOL silentOK = self.returnEmptyGraphQLJSON;
    NSURL *reqURL = request.URL ?: [NSURL URLWithString:@"https://graph.facebook.com/graphql"];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (silentOK) {
            NSData *emptyOK = [@"{\"data\":{},\"extensions\":{\"is_final\":true}}" dataUsingEncoding:NSUTF8StringEncoding];
            if ([delegate respondsToSelector:@selector(URLRequest:didReceiveResponse:)]) {
                NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:reqURL
                                                                      statusCode:200
                                                                     HTTPVersion:@"HTTP/1.1"
                                                                    headerFields:@{@"Content-Type": @"application/json"}];
                [delegate URLRequest:token didReceiveResponse:resp];
            }
            if ([delegate respondsToSelector:@selector(URLRequest:didReceiveData:)]) {
                [delegate URLRequest:token didReceiveData:emptyOK];
            }
            if ([delegate respondsToSelector:@selector(URLRequest:didCompleteWithError:)]) {
                [delegate URLRequest:token didCompleteWithError:nil];
            }
        } else {
            NSError *err = [NSError errorWithDomain:NSURLErrorDomain
                                               code:NSURLErrorNotConnectedToInternet
                                           userInfo:@{NSLocalizedDescriptionKey: @"Blocked by FocusFB"}];
            if ([delegate respondsToSelector:@selector(URLRequest:didCompleteWithError:)]) {
                [delegate URLRequest:token didCompleteWithError:err];
            }
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
    if (!gAdBlockerReady.load(std::memory_order_relaxed)) {
        return gOrigRCTHandlerForReq ? gOrigRCTHandlerForReq(self, _cmd, request) : nil;
    }
    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    if (prefs.enabled) {
        if (FocusFBIsStorySeenNetworkRequest(request)) {
            return [FFBBlockingRCTHandler sharedSilentSuccess];
        }

        NSString *queryName = FFBRCTExtractFriendlyName(request);
        if (prefs.blockAllAds && FFBIsDedicatedAdQueryName(queryName)) {
            gBlockedAdsCount.fetch_add(1, std::memory_order_relaxed);
            return [FFBBlockingRCTHandler sharedAdBlocker];
        }

        id origHandler = gOrigRCTHandlerForReq ? gOrigRCTHandlerForReq(self, _cmd, request) : nil;
        FFBFilterFlags flags = FFBReadCurrentFilterFlags();
        if (origHandler && flags.anyJSONActive() && FFBShouldFilterRCTResponseForQuery(queryName)) {
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
// Rimuove Ads, PYMK ("Persone che potresti conoscere"), Carosello Reels,
// Post Suggeriti e Barra Storie PRIMA che raggiungano la UICollectionView
// (zero celle fantasma, zero scatti durante lo scroll!)
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

static BOOL FFBClassIsFeedOrCommerceCandidate(NSString *clsName) {
    if (clsName.length < 4) return NO;
    // Non toccare mai oggetti di bootstrap/autenticazione/utente (es. FBMemViewer, FBMemUser, FBMemConfig*)
    return ([clsName containsString:@"Edge"] ||
            [clsName containsString:@"Story"] ||
            [clsName containsString:@"Stories"] ||
            [clsName containsString:@"Snacks"] ||
            [clsName containsString:@"FeedUnit"] ||
            [clsName containsString:@"Bucket"] ||
            [clsName containsString:@"Marketplace"] ||
            [clsName containsString:@"Commerce"] ||
            [clsName containsString:@"Sponsored"] ||
            [clsName containsString:@"AdBreak"] ||
            [clsName containsString:@"InstreamVideoAd"] ||
            [clsName containsString:@"BannerAd"] ||
            [clsName containsString:@"AdsFeed"] ||
            [clsName containsString:@"PYMK"] ||
            [clsName containsString:@"PeopleYouMayKnow"] ||
            [clsName containsString:@"FriendingPossibilities"] ||
            [clsName containsString:@"FriendSuggestions"] ||
            [clsName containsString:@"Shorts"] ||
            [clsName containsString:@"Reels"] ||
            [clsName containsString:@"Clips"] ||
            [clsName containsString:@"GroupsYouShouldJoin"] ||
            [clsName containsString:@"PagesYouMayLike"] ||
            [clsName containsString:@"ThreadsInFeed"] ||
            [clsName containsString:@"SingleBucketInlineViewer"]);
}

static BOOL FFBShouldFilterGraphQLModel(id model) {
    if (!model) return NO;

    FFBFilterFlags flags = FFBReadCurrentFilterFlags();
    if (!flags.anyActive()) return NO;

    Class cls = object_getClass(model);
    NSString *clsName = NSStringFromClass(cls) ?: @"";

    // Non filtrare il nodo figlio *SponsoredData* stesso, così il post padre mantiene [story sponsoredData] != nil
    if ([clsName containsString:@"SponsoredData"] || [clsName hasSuffix:@"AdData"]) {
        return NO;
    }
    if (!FFBClassIsFeedOrCommerceCandidate(clsName)) {
        return NO;
    }

    // 1. Controllo `category` (FBMemNewsFeedEdge, Marketplace Edges, Stories)
    SEL catSel = @selector(category);
    if (FFBMethodReturnsObject(cls, catSel)) {
        id rawCat = ((id (*)(id, SEL))objc_msgSend)(model, catSel);
        if ([rawCat isKindOfClass:NSString.class]) {
            NSString *cat = (NSString *)rawCat;
            if (flags.blockAds &&
                ([cat isEqualToString:@"SPONSORED"] ||
                 [cat isEqualToString:@"AD"] ||
                 [cat isEqualToString:@"ADS"] ||
                 [cat isEqualToString:@"MARKETPLACE_ADS"] ||
                 [cat isEqualToString:@"SPONSORED_STORY"] ||
                 [cat containsString:@"SPONSOR"])) {
                gBlockedAdsCount.fetch_add(1, std::memory_order_relaxed);
                return YES;
            }
            if (flags.hidePYMK &&
                ([cat isEqualToString:@"PYMK"] ||
                 [cat isEqualToString:@"PYMK_STORY"] ||
                 [cat isEqualToString:@"FRIENDING"])) {
                return YES;
            }
            if (flags.hideReelsCarousel &&
                ([cat isEqualToString:@"FB_SHORTS"] ||
                 [cat isEqualToString:@"FB_SHORTS_FALLBACK"] ||
                 [cat isEqualToString:@"SHORT_FORM_VIDEO"] ||
                 [cat containsString:@"FB_SHORTS"])) {
                return YES;
            }
            if (flags.hideSuggested &&
                ([cat isEqualToString:@"ENGAGEMENT"] ||
                 [cat isEqualToString:@"ENGAGEMENT_QP"] ||
                 [cat isEqualToString:@"RECOMMENDATION"])) {
                return YES;
            }
            if (flags.hideStoriesTray &&
                ([cat isEqualToString:@"MULTI_FB_STORIES_TRAY"] ||
                 [cat isEqualToString:@"STORIES_TRAY"])) {
                return YES;
            }
        }
    }

    // 2. Controllo `storyBucketType` (Ads, PYMK e Suggeriti dentro la riga Storie!)
    SEL bucketSel = @selector(storyBucketType);
    if (FFBMethodReturnsObject(cls, bucketSel)) {
        id bucket = ((id (*)(id, SEL))objc_msgSend)(model, bucketSel);
        if ([bucket isKindOfClass:NSString.class]) {
            NSString *bStr = (NSString *)bucket;
            if (flags.blockAds &&
                ([bStr isEqualToString:@"ADS"] ||
                 [bStr isEqualToString:@"AD"] ||
                 [bStr isEqualToString:@"SPONSORED"] ||
                 [bStr isEqualToString:@"SPONSORED_STORY"] ||
                 [bStr containsString:@"SPONSOR"])) {
                gBlockedAdsCount.fetch_add(1, std::memory_order_relaxed);
                return YES;
            }
            if (flags.hidePYMK &&
                ([bStr isEqualToString:@"PYMK_STORY"] ||
                 [bStr isEqualToString:@"PYMK"] ||
                 [bStr containsString:@"FRIEND_SUGGESTION"])) {
                return YES;
            }
            if (flags.hideSuggested &&
                ([bStr isEqualToString:@"SUGGESTED_STORY"] ||
                 [bStr containsString:@"PAGE_SUGGESTION"])) {
                return YES;
            }
        }
    }

    // 3. Controllo `sponsoredData`, `isSponsored` e classi Ad
    if (flags.blockAds) {
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

        if ([clsName containsString:@"Marketplace"] ||
            [clsName containsString:@"GroupCommerce"] ||
            [clsName containsString:@"CommerceProduct"]) {
            if (FFBIsMarketplaceModelSponsoredViaKVC(model)) {
                gBlockedAdsCount.fetch_add(1, std::memory_order_relaxed);
                return YES;
            }
        }
    }

    // 4. Rimozione "Persone che potresti conoscere" (PYMK)
    if (flags.hidePYMK && FFBIsPYMKTypenameString(clsName)) {
        return YES;
    }

    // 5. Rimozione Carosello Reels nel Feed
    if (flags.hideReelsCarousel && FFBIsReelsCarouselTypenameString(clsName)) {
        return YES;
    }

    // 6. Rimozione Gruppi, Pagine consigliate, Storie singole suggerite e Promo Threads
    if (flags.hideSuggested) {
        if (FFBIsSuggestedTypenameString(clsName)) {
            return YES;
        }
        if ([clsName containsString:@"FeedUnit"] && FFBIsThreadsPromoModel(model, cls)) {
            return YES;
        }
    }

    return NO;
}

static void *FFBHook_initWithFBPandoTree(void *rawSelf, SEL _cmd, void *tree) {
    void *rawModel = gOrigInitWithPandoTree ? gOrigInitWithPandoTree(rawSelf, _cmd, tree) : NULL;
    if (!rawModel || !gAdBlockerReady.load(std::memory_order_relaxed)) {
        return rawModel;
    }
    @try {
        id model = (__bridge id)rawModel;
        if (FFBShouldFilterGraphQLModel(model)) {
            id consumed = (__bridge_transfer id)rawModel;
            (void)consumed;
            return NULL;
        }
    } @catch (__unused NSException *e) {
    }
    return rawModel;
}

static void *FFBHook_initWithFBTree(void *rawSelf, SEL _cmd, void *tree) {
    void *rawModel = gOrigInitWithFBTree ? gOrigInitWithFBTree(rawSelf, _cmd, tree) : NULL;
    if (!rawModel || !gAdBlockerReady.load(std::memory_order_relaxed)) {
        return rawModel;
    }
    @try {
        id model = (__bridge id)rawModel;
        if (FFBShouldFilterGraphQLModel(model)) {
            id consumed = (__bridge_transfer id)rawModel;
            (void)consumed;
            return NULL;
        }
    } @catch (__unused NSException *e) {
    }
    return rawModel;
}

// ─────────────────────────────────────────────────────────────────────────────
// MOTORE 3: NSJSONSerialization Pruner (Bloks / Relay Nativo fuori da RCTNetworking)
// ─────────────────────────────────────────────────────────────────────────────

static id FFBPruneItemsInJSONNode(id obj, BOOL mutableContainers, const FFBFilterFlags &flags, NSUInteger depth, BOOL *outChanged) {
    if (!obj || depth > 20) return obj;

    if ([obj isKindOfClass:NSArray.class]) {
        NSArray *arr = (NSArray *)obj;
        if (arr.count == 0) return obj;

        BOOL localChanged = NO;
        NSMutableArray *cleaned = nil;

        for (NSUInteger i = 0; i < arr.count; i++) {
            id item = arr[i];
            BOOL isAd = NO;
            if (FFBShouldDropJSONItem(item, flags, &isAd)) {
                if (!localChanged) {
                    localChanged = YES;
                    cleaned = [NSMutableArray arrayWithCapacity:arr.count];
                    for (NSUInteger j = 0; j < i; j++) {
                        [cleaned addObject:arr[j]];
                    }
                }
                if (isAd) {
                    gBlockedAdsCount.fetch_add(1, std::memory_order_relaxed);
                }
                continue;
            }

            BOOL childChanged = NO;
            id newItem = FFBPruneItemsInJSONNode(item, mutableContainers, flags, depth + 1, &childChanged);
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
            id newVal = FFBPruneItemsInJSONNode(val, mutableContainers, flags, depth + 1, &childChanged);
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

static id FFBHook_JSONObjectWithData(id self,
                                     SEL _cmd,
                                     NSData *data,
                                     NSJSONReadingOptions opt,
                                     NSError * __autoreleasing *error) {
    id parsed = gOrigJSONWithData ? gOrigJSONWithData(self, _cmd, data, opt, error) : nil;
    if (!parsed || !data || gInsideInternalJSONPass || !gAdBlockerReady.load(std::memory_order_relaxed)) {
        return parsed;
    }

    // Filtra esclusivamente payload radice GraphQL (mai MobileConfig o file di configurazione)
    if (![parsed isKindOfClass:NSDictionary.class]) return parsed;
    NSDictionary *rootDict = (NSDictionary *)parsed;
    if (!rootDict[@"data"] && !rootDict[@"label"] && !rootDict[@"edges"]) {
        return parsed;
    }

    FFBFilterFlags flags = FFBReadCurrentFilterFlags();
    if (!flags.anyJSONActive()) return parsed;
    if (data.length < 64 || data.length > 8 * 1024 * 1024) return parsed;
    if (!FFBDataMayContainFilterableTokens(data, flags)) return parsed;

    @try {
        BOOL changed = NO;
        BOOL wantMutable = ((opt & NSJSONReadingMutableContainers) != 0);
        return FFBPruneItemsInJSONNode(parsed, wantMutable, flags, 0, &changed);
    } @catch (__unused NSException *e) {
        return parsed;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Installazione Hook AdBlock & Feed Cleanup (Immediata + Dyld Lazy Listener)
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
}

void FocusFBRetryLazyAdHooksIfNeeded(void) {
    if (!gAdBlockerReady.load(std::memory_order_relaxed)) return;
    if (gInstalledRCTHook && gInstalledPandoHook && gInstalledFBTreeHook && gInstalledJSONHook) {
        return;
    }
    if (NSThread.isMainThread) {
        FFBInstallAvailableAdHooksNow();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            FFBInstallAvailableAdHooksNow();
        });
    }
}

static void FFBActivateAdBlockerAfterBecomeActive(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FFBInstallAvailableAdHooksNow();
        gAdBlockerReady.store(true, std::memory_order_relaxed);

        // Ritenta pigramente sul main thread per framework React Native caricati dopo il login/apertura tab
        for (NSNumber *delaySec in @[@(1.5), @(4.0), @(8.0)]) {
            double d = delaySec.doubleValue;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                FFBInstallAvailableAdHooksNow();
            });
        }
    });
}

void FocusFBInstallAdBlocker(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            FFBActivateAdBlockerAfterBecomeActive();
        }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
                FFBActivateAdBlockerAfterBecomeActive();
            }
        });
    });
}
