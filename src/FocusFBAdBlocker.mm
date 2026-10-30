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
- (nullable id)adData;
- (nullable id)marketplaceAdData;
- (nullable id)boostedMarketplaceListing;
- (nullable id)promotedListingInfo;
- (nullable id)adImpressionClientToken;
- (nullable id)adID;
- (nullable id)adId;
- (nullable id)node;
- (nullable id)listing;
- (nullable id)story;
- (nullable id)tracking;
- (BOOL)isSponsored;
- (BOOL)isAd;
- (BOOL)isBoosted;
- (nullable id)storyBucketType;
@end

@protocol FFBRCTURLRequestDelegate <NSObject>
@optional
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

// Convenzione esatta ns_consumed (self +1) -> ns_returns_retained (+1) per i metodi -init*
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
        return blockAds || hidePYMK || hideReelsCarousel || hideSuggested || hideStoriesTray;
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
// Helper Runtime Sicuri (Zero Overhead NSMethodSignature)
// ─────────────────────────────────────────────────────────────────────────────

static BOOL FFBMethodReturnsObject(Class cls, SEL sel) {
    if (!cls || !sel) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m || method_getNumberOfArguments(m) != 2) return NO;
    const char *enc = method_getTypeEncoding(m);
    return (enc != NULL && enc[0] == '@');
}

static BOOL FFBMethodReturnsBool(Class cls, SEL sel) {
    if (!cls || !sel) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m || method_getNumberOfArguments(m) != 2) return NO;
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
// Riconoscimento Unificato Nodi/Edge Pubblicitari, Marketplace Ads, PYMK, Reels & Storie
// ─────────────────────────────────────────────────────────────────────────────

static inline BOOL FFBHasNonNullValue(NSDictionary *dict, NSString *key) {
    id v = dict[key];
    return (v != nil && ![v isKindOfClass:NSNull.class]);
}

static inline BOOL FFBHasTruthyBool(NSDictionary *dict, NSString *key) {
    id v = dict[key];
    if ([v isKindOfClass:NSNumber.class]) return [(NSNumber *)v boolValue];
    if ([v isKindOfClass:NSString.class]) return [(NSString *)v isEqualToString:@"true"] || [(NSString *)v isEqualToString:@"1"];
    return NO;
}

static BOOL FFBIsAdTypenameString(NSString *tn) {
    if (![tn isKindOfClass:NSString.class] || tn.length < 4) return NO;
    static NSRegularExpression *adTypeRegex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        adTypeRegex = [NSRegularExpression
            regularExpressionWithPattern:@"(?:Ads?[A-Z])|Sponsored|(?:StoryAd$)|(?:BannerAd$)|(?:AdStory)|(?:AdUnit)|(?:AdCard)|(?:BoostedListing)|(?:PromotedListing)|(?:MarketplaceAd)"
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

static BOOL FFBIsStoriesTrayTypenameString(NSString *tn) {
    if (![tn isKindOfClass:NSString.class] || tn.length < 6) return NO;
    return ([tn rangeOfString:@"StoriesTray" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [tn rangeOfString:@"SnacksTray" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [tn rangeOfString:@"InlineSnacks" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [tn rangeOfString:@"StoriesSingleBucketInlineViewer" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [tn rangeOfString:@"UnifiedStoriesConnection" options:NSCaseInsensitiveSearch].location != NSNotFound);
}

static BOOL FFBTrackingStringLooksSponsored(NSString *tracking) {
    if (![tracking isKindOfClass:NSString.class] || tracking.length < 10 || tracking.length > 8192) return NO;
    return ([tracking containsString:@"\"is_sponsored\":true"] ||
            [tracking containsString:@"\"is_sponsored\":1"] ||
            [tracking containsString:@"\"ad_id\":\""] ||
            [tracking containsString:@"\"boosted_component\""] ||
            [tracking containsString:@"\"ad_impression_token\""]);
}

static BOOL FFBDictHasDirectFilterMarkers(NSDictionary *d, const FFBFilterFlags &flags, BOOL *outIsAd) {
    if (![d isKindOfClass:NSDictionary.class]) return NO;

    for (NSString *catKey in @[@"category", @"story_type", @"edge_type", @"feed_edge_type", @"item_type"]) {
        NSString *cat = d[catKey];
        if (![cat isKindOfClass:NSString.class] || cat.length == 0) continue;
        NSString *upper = cat.uppercaseString;
        if (flags.blockAds &&
            ([upper isEqualToString:@"SPONSORED"] ||
             [upper isEqualToString:@"AD"] ||
             [upper isEqualToString:@"ADS"] ||
             [upper isEqualToString:@"MARKETPLACE_ADS"] ||
             [upper isEqualToString:@"MARKETPLACE_AD"] ||
             [upper isEqualToString:@"SPONSORED_STORY"] ||
             [upper containsString:@"SPONSOR"] ||
             [upper containsString:@"BOOSTED"] ||
             [upper containsString:@"PROMOTED"])) {
            if (outIsAd) *outIsAd = YES;
            return YES;
        }
        if (flags.hidePYMK &&
            ([upper isEqualToString:@"PYMK"] ||
             [upper isEqualToString:@"PYMK_STORY"] ||
             [upper isEqualToString:@"FRIENDING"])) {
            return YES;
        }
        if (flags.hideReelsCarousel &&
            ([upper isEqualToString:@"FB_SHORTS"] ||
             [upper isEqualToString:@"FB_SHORTS_FALLBACK"] ||
             [upper isEqualToString:@"SHORT_FORM_VIDEO"] ||
             [upper containsString:@"FB_SHORTS"])) {
            return YES;
        }
        if (flags.hideSuggested &&
            ([upper isEqualToString:@"ENGAGEMENT"] ||
             [upper isEqualToString:@"ENGAGEMENT_QP"] ||
             [upper isEqualToString:@"RECOMMENDATION"])) {
            return YES;
        }
        if (flags.hideStoriesTray &&
            ([upper isEqualToString:@"MULTI_FB_STORIES_TRAY"] ||
             [upper isEqualToString:@"STORIES_TRAY"] ||
             [upper isEqualToString:@"SNACKS_TRAY"] ||
             [upper isEqualToString:@"FB_STORIES"])) {
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
        if (flags.hideStoriesTray && FFBIsStoriesTrayTypenameString(tn)) {
            return YES;
        }
    }

    if (!flags.blockAds) return NO;

    if (FFBHasNonNullValue(d, @"sponsored_data") ||
        FFBHasNonNullValue(d, @"sponsoredData") ||
        FFBHasNonNullValue(d, @"ad_data") ||
        FFBHasNonNullValue(d, @"adData") ||
        FFBHasNonNullValue(d, @"marketplace_ad_data") ||
        FFBHasNonNullValue(d, @"marketplaceAdData") ||
        FFBHasNonNullValue(d, @"boosted_marketplace_listing") ||
        FFBHasNonNullValue(d, @"boostedMarketplaceListing") ||
        FFBHasNonNullValue(d, @"promoted_listing_info") ||
        FFBHasNonNullValue(d, @"promotedListingInfo") ||
        FFBHasNonNullValue(d, @"ad_impression_client_token") ||
        FFBHasNonNullValue(d, @"ad_logging_info") ||
        FFBHasNonNullValue(d, @"sponsored_impression_url")) {
        if (outIsAd) *outIsAd = YES;
        return YES;
    }

    for (NSString *adIdKey in @[@"ad_id", @"adId"]) {
        id adId = d[adIdKey];
        if (([adId isKindOfClass:NSString.class] && ((NSString *)adId).length > 0) ||
            ([adId isKindOfClass:NSNumber.class] && [(NSNumber *)adId longLongValue] > 0)) {
            if (outIsAd) *outIsAd = YES;
            return YES;
        }
    }

    if (FFBHasTruthyBool(d, @"is_sponsored") ||
        FFBHasTruthyBool(d, @"isSponsored") ||
        FFBHasTruthyBool(d, @"is_ad") ||
        FFBHasTruthyBool(d, @"isAd") ||
        FFBHasTruthyBool(d, @"is_boosted") ||
        FFBHasTruthyBool(d, @"isBoosted") ||
        FFBHasTruthyBool(d, @"is_promoted") ||
        FFBHasTruthyBool(d, @"isPromoted")) {
        if (outIsAd) *outIsAd = YES;
        return YES;
    }

    if (FFBTrackingStringLooksSponsored(d[@"tracking"])) {
        if (outIsAd) *outIsAd = YES;
        return YES;
    }

    return NO;
}

// Evita di scartare un contenitore radice (es. "marketplace_feed_stories" o "viewer") che contiene più edge organici
static BOOL FFBDictContainsMultiItemConnection(NSDictionary *dict, NSUInteger depth) {
    if (![dict isKindOfClass:NSDictionary.class] || depth > 2) return NO;
    for (NSString *connKey in @[@"edges", @"nodes", @"feed_units", @"units", @"results"]) {
        id arr = dict[connKey];
        if ([arr isKindOfClass:NSArray.class] && ((NSArray *)arr).count >= 2) {
            return YES;
        }
    }
    for (id key in dict) {
        id val = dict[key];
        if ([val isKindOfClass:NSDictionary.class]) {
            if (FFBDictContainsMultiItemConnection((NSDictionary *)val, depth + 1)) {
                return YES;
            }
        }
    }
    return NO;
}

// Scansiona un singolo edge fino a profondità 4 per catturare annunci Marketplace annidati (es. edge.node.renderable.sponsored_data)
static BOOL FFBDictSubtreeMatchesFilter(NSDictionary *dict,
                                        const FFBFilterFlags &flags,
                                        NSUInteger depth,
                                        BOOL *outIsAd) {
    if (![dict isKindOfClass:NSDictionary.class] || depth > 4) return NO;
    if (FFBDictHasDirectFilterMarkers(dict, flags, outIsAd)) return YES;
    if (depth >= 4) return NO;

    for (id key in dict) {
        id val = dict[key];
        if ([val isKindOfClass:NSDictionary.class]) {
            if (FFBDictSubtreeMatchesFilter((NSDictionary *)val, flags, depth + 1, outIsAd)) {
                return YES;
            }
        }
    }
    return NO;
}

static BOOL FFBShouldDropJSONItem(id item, const FFBFilterFlags &flags, BOOL *outIsAd) {
    if (![item isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *dict = (NSDictionary *)item;
    if (FFBDictContainsMultiItemConnection(dict, 0)) {
        return NO;
    }
    return FFBDictSubtreeMatchesFilter(dict, flags, 0, outIsAd);
}

static inline BOOL FFBBytesContainASCII(const uint8_t *buf, size_t bufLen, const char *pat, size_t patLen) {
    const uint8_t *p = reinterpret_cast<const uint8_t *>(pat);
    return std::search(buf, buf + bufLen, p, p + patLen) != (buf + bufLen);
}

static BOOL FFBDataMayContainFilterableTokens(NSData *data, const FFBFilterFlags &flags) {
    const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
    size_t len = (size_t)data.length;
    if (!bytes || len < 40) return NO;

    if (flags.blockAds) {
        if (FFBBytesContainASCII(bytes, len, "sponsored", 9)) return YES;
        if (FFBBytesContainASCII(bytes, len, "SPONSORED", 9)) return YES;
        if (FFBBytesContainASCII(bytes, len, "Sponsored", 9)) return YES;
        if (FFBBytesContainASCII(bytes, len, "ad_data", 7))   return YES;
        if (FFBBytesContainASCII(bytes, len, "adData", 6))    return YES;
        if (FFBBytesContainASCII(bytes, len, "\"ad_id\"", 7)) return YES;
        if (FFBBytesContainASCII(bytes, len, "\"adId\"", 6))  return YES;
        if (FFBBytesContainASCII(bytes, len, "is_ad", 5))     return YES;
        if (FFBBytesContainASCII(bytes, len, "boosted", 7))   return YES;
        if (FFBBytesContainASCII(bytes, len, "Boosted", 7))   return YES;
        if (FFBBytesContainASCII(bytes, len, "promoted", 8))  return YES;
        if (FFBBytesContainASCII(bytes, len, "Promoted", 8))  return YES;
        if (FFBBytesContainASCII(bytes, len, "AdStory", 7))   return YES;
        if (FFBBytesContainASCII(bytes, len, "AdsFeed", 7))   return YES;
        if (FFBBytesContainASCII(bytes, len, "AdUnit", 6))    return YES;
        if (FFBBytesContainASCII(bytes, len, "AdCard", 6))    return YES;
        if (FFBBytesContainASCII(bytes, len, "BannerAd", 8))  return YES;
        if (FFBBytesContainASCII(bytes, len, "MarketplaceAd", 13)) return YES;
        if (FFBBytesContainASCII(bytes, len, "\"Ads", 4))     return YES;
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
    if (flags.hideStoriesTray) {
        if (FFBBytesContainASCII(bytes, len, "STORIES_TRAY", 12))           return YES;
        if (FFBBytesContainASCII(bytes, len, "StoriesTray", 11))            return YES;
        if (FFBBytesContainASCII(bytes, len, "SnacksTray", 10))             return YES;
        if (FFBBytesContainASCII(bytes, len, "unified_stories", 15))        return YES;
        if (FFBBytesContainASCII(bytes, len, "stories_tray", 12))           return YES;
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
            @"MarketplaceHomeFeedAdsThemedQuery",
            @"MarketplacePDPBoostedListingAdsQuery",
            @"MarketplacePDPPersonalizedAdsQuery",
            @"MarketplaceProductDetailsPageRelatedAdsDetailQuery",
            @"MarketplaceSearchAdsQuery",
            @"MarketplaceSearchAdsPaginationQuery",
            @"MarketplaceCategoryFeedAdsQuery",
            @"MarketplaceBrowseAdsQuery",
            @"MarketplaceForYouFeedAdsQuery",
            @"MarketplaceLocalFeedAdsQuery"
        ]];
        adQueryRegex = [NSRegularExpression
            regularExpressionWithPattern:@"(?:^(?:Comet)?(?:Marketplace|Commerce)\\w*(?:Ads?|Sponsored|Boosted|Promoted)(?:[A-Z]\\w*)?(?:Query|RendererQuery|PaginationQuery)$)|(?:AdsQueryRendererQuery$)|(?:BoostedListingAds)|(?:PromotedListingAds)|(?:RelatedAdsDetailQuery$)"
                                 options:0
                                   error:nil];
    });

    if ([exactBlocked containsObject:name]) return YES;
    return [adQueryRegex firstMatchInString:name options:0 range:NSMakeRange(0, name.length)] != nil;
}

static BOOL FFBIsStoriesTrayQueryName(NSString *name) {
    if (name.length == 0) return NO;
    return ([name rangeOfString:@"SnacksTray" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [name rangeOfString:@"StoriesTray" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [name rangeOfString:@"UnifiedStoriesBuckets" options:NSCaseInsensitiveSearch].location != NSNotFound);
}

static BOOL FFBShouldFilterRCTResponse(NSURLRequest *request, NSString * _Nullable name) {
    if (name.length > 0) {
        // Non filtrare mutazioni di scrittura (es. invio messaggio / creazione annuncio)
        if ([name hasSuffix:@"Mutation"]) return NO;
        return YES;
    }
    NSString *path = request.URL.path.lowercaseString ?: @"";
    return [path containsString:@"graphql"];
}

// Rimozione Bottom-Up: prima ripulisce gli array figli (es. edges interni), poi scarta il singolo edge sponsorizzato!
static NSUInteger FFBStripMutableJSONInPlace(id obj, const FFBFilterFlags &flags, NSUInteger depth, NSUInteger *outAdsCount) {
    if (!obj || depth > 26) return 0;
    NSUInteger removed = 0;

    if ([obj isKindOfClass:NSMutableArray.class]) {
        NSMutableArray *arr = (NSMutableArray *)obj;
        for (NSInteger i = (NSInteger)arr.count - 1; i >= 0; i--) {
            id item = arr[(NSUInteger)i];
            removed += FFBStripMutableJSONInPlace(item, flags, depth + 1, outAdsCount);

            BOOL isAd = NO;
            if (FFBShouldDropJSONItem(item, flags, &isAd)) {
                [arr removeObjectAtIndex:(NSUInteger)i];
                removed++;
                if (isAd && outAdsCount) (*outAdsCount)++;
            }
        }
    } else if ([obj isKindOfClass:NSMutableDictionary.class]) {
        NSMutableDictionary *dict = (NSMutableDictionary *)obj;

        if (flags.hideStoriesTray) {
            for (NSString *trayKey in @[@"unified_stories_buckets", @"stories_tray", @"snacks_tray", @"stories_buckets"]) {
                id trayVal = dict[trayKey];
                if ([trayVal isKindOfClass:NSMutableDictionary.class]) {
                    NSMutableDictionary *trayDict = (NSMutableDictionary *)trayVal;
                    if ([trayDict[@"edges"] isKindOfClass:NSMutableArray.class] &&
                        ((NSMutableArray *)trayDict[@"edges"]).count > 0) {
                        removed += ((NSMutableArray *)trayDict[@"edges"]).count;
                        [(NSMutableArray *)trayDict[@"edges"] removeAllObjects];
                    }
                    if ([trayDict[@"nodes"] isKindOfClass:NSMutableArray.class] &&
                        ((NSMutableArray *)trayDict[@"nodes"]).count > 0) {
                        removed += ((NSMutableArray *)trayDict[@"nodes"]).count;
                        [(NSMutableArray *)trayDict[@"nodes"] removeAllObjects];
                    }
                }
            }
        }

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
    if (!data || data.length < 40 || data.length > 16 * 1024 * 1024) return data;

    FFBFilterFlags flags = FFBReadCurrentFilterFlags();
    if (!flags.anyJSONActive()) return data;

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

            BOOL hadLoopPrefix = NO;
            NSString *jsonCandidate = trimmed;
            if ([jsonCandidate hasPrefix:@"for (;;);"]) {
                hadLoopPrefix = YES;
                jsonCandidate = [jsonCandidate substringFromIndex:9];
            }

            NSData *partData = [jsonCandidate dataUsingEncoding:NSUTF8StringEncoding];
            if (!partData || !FFBDataMayContainFilterableTokens(partData, flags)) {
                [outParts addObject:part];
                continue;
            }

            id json = [NSJSONSerialization JSONObjectWithData:partData
                                                      options:NSJSONReadingMutableContainers
                                                        error:nil];
            if (!json) {
                // Mantiene intatte eventuali righe boundary/metadata senza annullare l'intero payload
                [outParts addObject:part];
                continue;
            }

            NSUInteger removedHere = FFBStripMutableJSONInPlace(json, flags, 0, &totalAds);
            if (removedHere == 0) {
                [outParts addObject:part];
                continue;
            }

            NSData *reserialized = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
            NSString *reStr = reserialized ? [[NSString alloc] initWithData:reserialized encoding:NSUTF8StringEncoding] : nil;
            if (!reStr) {
                [outParts addObject:part];
                continue;
            }
            [outParts addObject:(hadLoopPrefix ? [@"for (;;);" stringByAppendingString:reStr] : reStr)];
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
    NSString *q = FFBRCTExtractFriendlyName(request);
    return FFBIsDedicatedAdQueryName(q) || FocusFBIsStorySeenNetworkRequest(request);
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

- (void)URLRequest:(id)requestToken didReceiveResponse:(NSURLResponse *)response {
    if ([self.realDelegate respondsToSelector:@selector(URLRequest:didReceiveResponse:)]) {
        [self.realDelegate URLRequest:requestToken didReceiveResponse:response];
    }
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
        if (prefs.hideStoriesTray && FFBIsStoriesTrayQueryName(queryName)) {
            return [FFBBlockingRCTHandler sharedSilentSuccess];
        }

        id origHandler = gOrigRCTHandlerForReq ? gOrigRCTHandlerForReq(self, _cmd, request) : nil;
        FFBFilterFlags flags = FFBReadCurrentFilterFlags();
        if (origHandler && flags.anyJSONActive() && FFBShouldFilterRCTResponse(request, queryName)) {
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

static BOOL FFBModelInstanceHasDirectAdSignals(id obj) {
    if (!obj) return NO;
    Class cls = object_getClass(obj);
    NSString *clsName = NSStringFromClass(cls) ?: @"";
    if ([clsName containsString:@"SponsoredData"] || [clsName hasSuffix:@"AdData"]) {
        return NO;
    }

    if (FFBIsAdTypenameString(clsName) ||
        [clsName containsString:@"InstreamVideoAd"] ||
        [clsName containsString:@"VideoAdBreak"]) {
        return YES;
    }

    SEL objAdSelectors[] = {
        @selector(sponsoredData),
        @selector(adData),
        @selector(marketplaceAdData),
        @selector(boostedMarketplaceListing),
        @selector(promotedListingInfo),
        @selector(adImpressionClientToken)
    };
    for (size_t i = 0; i < sizeof(objAdSelectors) / sizeof(objAdSelectors[0]); i++) {
        SEL sel = objAdSelectors[i];
        if (FFBMethodReturnsObject(cls, sel)) {
            id val = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
            if (val != nil && ![val isKindOfClass:NSNull.class]) {
                return YES;
            }
        }
    }

    SEL idSelectors[] = { @selector(adID), @selector(adId) };
    for (size_t i = 0; i < sizeof(idSelectors) / sizeof(idSelectors[0]); i++) {
        SEL sel = idSelectors[i];
        if (FFBMethodReturnsObject(cls, sel)) {
            id val = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
            if (([val isKindOfClass:NSString.class] && ((NSString *)val).length > 0) ||
                ([val isKindOfClass:NSNumber.class] && [(NSNumber *)val longLongValue] > 0)) {
                return YES;
            }
        }
    }

    SEL boolSelectors[] = { @selector(isSponsored), @selector(isAd), @selector(isBoosted) };
    for (size_t i = 0; i < sizeof(boolSelectors) / sizeof(boolSelectors[0]); i++) {
        SEL sel = boolSelectors[i];
        if (FFBMethodReturnsBool(cls, sel)) {
            if (((BOOL (*)(id, SEL))objc_msgSend)(obj, sel)) {
                return YES;
            }
        }
    }

    if (FFBMethodReturnsObject(cls, @selector(tracking))) {
        id tr = ((id (*)(id, SEL))objc_msgSend)(obj, @selector(tracking));
        if ([tr isKindOfClass:NSString.class] && FFBTrackingStringLooksSponsored((NSString *)tr)) {
            return YES;
        }
    }

    return NO;
}

static BOOL FFBClassIsFeedOrCommerceCandidate(NSString *clsName) {
    if (clsName.length < 4) return NO;
    return ([clsName containsString:@"Edge"] ||
            [clsName containsString:@"Story"] ||
            [clsName containsString:@"Stories"] ||
            [clsName containsString:@"Snacks"] ||
            [clsName containsString:@"FeedUnit"] ||
            [clsName containsString:@"Bucket"] ||
            [clsName containsString:@"Marketplace"] ||
            [clsName containsString:@"Commerce"] ||
            [clsName containsString:@"ProductItem"] ||
            [clsName containsString:@"Listing"] ||
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

    if ([clsName containsString:@"SponsoredData"] || [clsName hasSuffix:@"AdData"]) {
        return NO;
    }
    if (!FFBClassIsFeedOrCommerceCandidate(clsName)) {
        return NO;
    }

    // 1. Controllo `category`
    SEL catSel = @selector(category);
    if (FFBMethodReturnsObject(cls, catSel)) {
        id rawCat = ((id (*)(id, SEL))objc_msgSend)(model, catSel);
        if ([rawCat isKindOfClass:NSString.class]) {
            NSString *cat = [(NSString *)rawCat uppercaseString];
            if (flags.blockAds &&
                ([cat isEqualToString:@"SPONSORED"] ||
                 [cat isEqualToString:@"AD"] ||
                 [cat isEqualToString:@"ADS"] ||
                 [cat isEqualToString:@"MARKETPLACE_ADS"] ||
                 [cat isEqualToString:@"MARKETPLACE_AD"] ||
                 [cat isEqualToString:@"SPONSORED_STORY"] ||
                 [cat containsString:@"SPONSOR"] ||
                 [cat containsString:@"BOOSTED"] ||
                 [cat containsString:@"PROMOTED"])) {
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
                 [cat isEqualToString:@"STORIES_TRAY"] ||
                 [cat isEqualToString:@"SNACKS_TRAY"] ||
                 [cat isEqualToString:@"FB_STORIES"])) {
                return YES;
            }
        }
    }

    // 2. Controllo `storyBucketType`
    SEL bucketSel = @selector(storyBucketType);
    if (FFBMethodReturnsObject(cls, bucketSel)) {
        id bucket = ((id (*)(id, SEL))objc_msgSend)(model, bucketSel);
        if ([bucket isKindOfClass:NSString.class]) {
            NSString *bStr = [(NSString *)bucket uppercaseString];
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

    // 3. Controllo barra Storie
    if (flags.hideStoriesTray && FFBIsStoriesTrayTypenameString(clsName)) {
        return YES;
    }

    // 4. Controllo Ads su `model` e sui suoi figli diretti (`node`, `listing`, `story`)
    if (flags.blockAds) {
        if (FFBModelInstanceHasDirectAdSignals(model)) {
            gBlockedAdsCount.fetch_add(1, std::memory_order_relaxed);
            return YES;
        }
        SEL childSels[] = { @selector(node), @selector(listing), @selector(story) };
        for (size_t i = 0; i < sizeof(childSels) / sizeof(childSels[0]); i++) {
            SEL cSel = childSels[i];
            if (FFBMethodReturnsObject(cls, cSel)) {
                id child = ((id (*)(id, SEL))objc_msgSend)(model, cSel);
                if (child && FFBModelInstanceHasDirectAdSignals(child)) {
                    gBlockedAdsCount.fetch_add(1, std::memory_order_relaxed);
                    return YES;
                }
            }
        }
    }

    // 5. PYMK, Carosello Reels e Suggeriti
    if (flags.hidePYMK && FFBIsPYMKTypenameString(clsName)) {
        return YES;
    }
    if (flags.hideReelsCarousel && FFBIsReelsCarouselTypenameString(clsName)) {
        return YES;
    }
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
// MOTORE 3: NSJSONSerialization Pruner Bottom-Up (Bloks / Relay Nativo)
// ─────────────────────────────────────────────────────────────────────────────

static id FFBPruneItemsInJSONNode(id obj, BOOL mutableContainers, const FFBFilterFlags &flags, NSUInteger depth, BOOL *outChanged) {
    if (!obj || depth > 22) return obj;

    if ([obj isKindOfClass:NSArray.class]) {
        NSArray *arr = (NSArray *)obj;
        if (arr.count == 0) return obj;

        BOOL localChanged = NO;
        NSMutableArray *cleaned = nil;

        for (NSUInteger i = 0; i < arr.count; i++) {
            id origItem = arr[i];
            BOOL childChanged = NO;
            id itemAfterChildPass = FFBPruneItemsInJSONNode(origItem, mutableContainers, flags, depth + 1, &childChanged);
            id candidate = childChanged ? (itemAfterChildPass ?: origItem) : origItem;

            BOOL isAd = NO;
            if (FFBShouldDropJSONItem(candidate, flags, &isAd)) {
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

            if (childChanged && !localChanged) {
                localChanged = YES;
                cleaned = [NSMutableArray arrayWithCapacity:arr.count];
                for (NSUInteger j = 0; j < i; j++) {
                    [cleaned addObject:arr[j]];
                }
            }
            if (localChanged) {
                [cleaned addObject:candidate];
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
            if (flags.hideStoriesTray && [key isKindOfClass:NSString.class]) {
                NSString *ks = (NSString *)key;
                if (([ks isEqualToString:@"unified_stories_buckets"] ||
                     [ks isEqualToString:@"stories_tray"] ||
                     [ks isEqualToString:@"snacks_tray"]) &&
                    [val isKindOfClass:NSDictionary.class]) {
                    NSMutableDictionary *emptyTray = [(NSDictionary *)val mutableCopy];
                    if ([emptyTray[@"edges"] isKindOfClass:NSArray.class] && ((NSArray *)emptyTray[@"edges"]).count > 0) {
                        emptyTray[@"edges"] = mutableContainers ? [NSMutableArray array] : @[];
                        if (!localChanged) { localChanged = YES; mutDict = [dict mutableCopy]; }
                        mutDict[key] = mutableContainers ? emptyTray : [emptyTray copy];
                        continue;
                    }
                }
            }

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

    if (![parsed isKindOfClass:NSDictionary.class]) return parsed;
    NSDictionary *rootDict = (NSDictionary *)parsed;
    if (!rootDict[@"data"] && !rootDict[@"label"] && !rootDict[@"edges"]) {
        return parsed;
    }

    FFBFilterFlags flags = FFBReadCurrentFilterFlags();
    if (!flags.anyJSONActive()) return parsed;
    if (data.length < 48 || data.length > 10 * 1024 * 1024) return parsed;
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
// Installazione Immediata Post-Launch + Aggancio Rapido per Framework Lazy
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

void FocusFBInstallAdBlocker(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FFBInstallAvailableAdHooksNow();
        gAdBlockerReady.store(true, std::memory_order_relaxed);

        // Intervalli ravvicinati fin dai primi 50ms per intercettare la prima query di Marketplace all'avvio
        NSArray<NSNumber *> *delays = @[@(0.05), @(0.15), @(0.40), @(0.90), @(2.0), @(4.5), @(8.0)];
        for (NSNumber *delaySec in delays) {
            double d = delaySec.doubleValue;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                FFBInstallAvailableAdHooksNow();
            });
        }
    });
}
