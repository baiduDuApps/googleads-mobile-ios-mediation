// Copyright 2016 Google Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import "GADDuAdNativeAd.h"

@import GoogleMobileAds;
@import DUModuleSDK;

#import "GADDuAdAdapterDelegate.h"
#import "GADDuAdError.h"

static NSString *const GADNativeAdCoverImage = @"1";
static NSString *const GADNativeAdIcon = @"2";

@interface GADDuAdNativeAd() <GADMediatedNativeAppInstallAd, GADMediatedNativeAdDelegate,
DUNativeAdDelegate> {
    /// Connector from the Google Mobile Ads SDK to receive ad configurations.
    __weak id<GADMAdNetworkConnector> _connector;
    
    /// Adapter for receiving ad request notifications.
    __weak id<GADMAdNetworkAdapter> _adapter;
    
    /// Native ad image loading options.
    GADNativeAdImageAdLoaderOptions *_nativeAdImageAdLoaderOptions;
    
    /// Native ad view options.
    GADNativeAdViewAdOptions *_nativeAdViewAdOptions;
    
    /// Native ad obtained from DuAd's Audience Network.
    DUNativeAd *_nativeAd;
    
    /// Array of GADNativeAdImage objects related to the advertised application.
    NSArray *_images;
    
    /// Application icon.
    GADNativeAdImage *_icon;
    
    /// A set of strings representing loaded images.
    NSMutableSet *_loadedImages;
    
    /// A set of string representing all native ad images.
    NSSet *_nativeAdImages;
    
    /// Serializes ivar usage.
    dispatch_queue_t _lockQueue;
    
    /// YES if an impression has been logged.
    BOOL _impressionLogged;
}

@end

@implementation GADDuAdNativeAd

/// Empty method to bypass Apple's private method checking since
/// GADMediatedNativeAdNotificationSource's mediatedNativeAdDidRecordImpression method is
/// dynamically called by this class's instances.
+ (void)mediatedNativeAdDidRecordImpression:(id<GADMediatedNativeAd>)mediatedNativeAd {
}

- (instancetype)initWithGADMAdNetworkConnector:(id<GADMAdNetworkConnector>)connector
                                       adapter:(id<GADMAdNetworkAdapter>)adapter {
    self = [super init];
    if (self) {
        _adapter = adapter;
        _connector = connector;
        _loadedImages = [[NSMutableSet alloc] init];
        _nativeAdImages = [[NSSet alloc] initWithObjects:GADNativeAdCoverImage, GADNativeAdIcon, nil];
        _lockQueue = dispatch_queue_create("du-native-ad", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)getNativeAdWithAdTypes:(NSArray *)adTypes options:(NSArray *)options {
    id<GADMAdNetworkConnector> strongConnector = _connector;
    id<GADMAdNetworkAdapter> strongAdapter = _adapter;
    
    // DuAd only supports app install ads.
    if (![adTypes containsObject:kGADAdLoaderAdTypeNativeAppInstall] ||
        ![adTypes containsObject:kGADAdLoaderAdTypeNativeContent]) {
        NSError *error =
        GADDUErrorWithDescription(@"Ad types must include kGADAdLoaderAdTypeNativeAppInstall and "
                                  @"kGADAdLoaderAdTypeNativeContent.");
        [strongConnector adapter:strongAdapter didFailAd:error];
        return;
    }
    
    for (GADAdLoaderOptions *option in options) {
        if ([option isKindOfClass:[GADNativeAdImageAdLoaderOptions class]]) {
            _nativeAdImageAdLoaderOptions = (GADNativeAdImageAdLoaderOptions *)option;
        } else if ([option isKindOfClass:[GADNativeAdViewAdOptions class]]) {
            _nativeAdViewAdOptions = (GADNativeAdViewAdOptions *)option;
        }
    }
    
    if (!strongConnector || !strongAdapter) {
        return;
    }
    
    // -[DUNativeAd initWithPlacementID:] throws an NSInvalidArgumentException if the placement ID is
    // nil.
    NSString *placementID = [strongConnector publisherId];
    if (!placementID) {
        NSError *error = GADDUErrorWithDescription(@"Placement ID cannot be nil.");
        [strongConnector adapter:strongAdapter didFailAd:error];
        return;
    }
    
    _nativeAd = [[DUNativeAd alloc] initWithPlacementID:placementID];
    if (!_nativeAd) {
        NSString *description = [[NSString alloc]
                                 initWithFormat:@"Failed to initialize %@.", NSStringFromClass([DUNativeAd class])];
        NSError *error = GADDUErrorWithDescription(description);
        [strongConnector adapter:strongAdapter didFailAd:error];
        return;
    }
    _nativeAd.delegate = self;
    [_nativeAd loadAd];
}

- (NSDictionary *)extraAssets {
    return nil;
}

- (void)stopBeingDelegate {
    _nativeAd.delegate = nil;
}

- (void)loadNativeAdImages {
    [_loadedImages removeAllObjects];
    if (_nativeAdImageAdLoaderOptions.disableImageLoading) {
        // Set scale as 1 since DuAd does not provide image scale.
        GADNativeAdImage *nativeAdImage =
        [[GADNativeAdImage alloc] initWithURL:[NSURL URLWithString:_nativeAd.imgeUrl] scale:1];
        if (nativeAdImage) {
            _images = @[ nativeAdImage ];
        }
        _icon = [[GADNativeAdImage alloc] initWithURL:[NSURL URLWithString:self->_nativeAd.iconUrl] scale:1];
        [self nativeAdImagesReady];
    } else {
        // Load icon and cover image, and notify the connector when completed.
        [self loadCoverImage];
        [self loadIcon];
    }
}

- (void)loadCoverImage {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSData *imageData = [NSData dataWithContentsOfURL:[NSURL URLWithString:self->_nativeAd.imgeUrl]];
        UIImage *image = [UIImage imageWithData:imageData];
        if (image) {
            GADNativeAdImage *nativeAdImage = [[GADNativeAdImage alloc] initWithImage:image];
            if (nativeAdImage) {
                self->_images = @[ nativeAdImage ];
            }
        }
        [self completedLoadingNativeAdImage:GADNativeAdCoverImage];
    });
}

- (void)loadIcon {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSData *iconData = [NSData dataWithContentsOfURL:[NSURL URLWithString:self->_nativeAd.iconUrl]];
        UIImage *icon = [UIImage imageWithData:iconData];
        if (icon) {
            self->_icon = [[GADNativeAdImage alloc] initWithImage:icon];
        }
        [self completedLoadingNativeAdImage:GADNativeAdIcon];
    });
}

- (void)completedLoadingNativeAdImage:(NSString *)image {
    __block BOOL loadedAllImages = NO;
    dispatch_sync(_lockQueue, ^{
        [self->_loadedImages addObject:image];
        loadedAllImages = [self->_loadedImages isEqual:self->_nativeAdImages];
    });
    
    if (!loadedAllImages) {
        return;
    }
    
    if (_images && _icon) {
        [self nativeAdImagesReady];
        return;
    }
    
    id<GADMAdNetworkAdapter> strongAdapter = self->_adapter;
    id<GADMAdNetworkConnector> strongConnector = self->_connector;
    NSString *errorMessage = [[NSString alloc] initWithFormat:@"Unable to load native ad image."];
    [strongConnector adapter:strongAdapter didFailAd:GADDUErrorWithDescription(errorMessage)];
}

- (void)nativeAdImagesReady {
    id<GADMAdNetworkAdapter> strongAdapter = self->_adapter;
    id<GADMAdNetworkConnector> strongConnector = self->_connector;
    [strongConnector adapter:strongAdapter didReceiveMediatedNativeAd:self];
}

#pragma mark - GADMediatedNativeAd

- (id<GADMediatedNativeAdDelegate>)mediatedNativeAdDelegate {
    return self;
}

#pragma mark - GADMediatedNativeAppInstallAd

- (NSString *)headline {
    NSString *__block headline = nil;
    dispatch_sync(_lockQueue, ^{
        headline = [self->_nativeAd.title copy];
    });
    return headline;
}

- (NSArray *)images {
    NSArray *__block images = nil;
    dispatch_sync(_lockQueue, ^{
        images = [self->_images copy];
    });
    return images;
}

- (NSString *)body {
    NSString *__block body = nil;
    dispatch_sync(_lockQueue, ^{
        body = [self->_nativeAd.shortDesc copy];
    });
    return body;
}

- (GADNativeAdImage *)icon {
    GADNativeAdImage *__block icon = nil;
    dispatch_sync(_lockQueue, ^{
        icon = self->_icon;
    });
    return icon;
}

- (NSString *)callToAction {
    NSString *__block callToAction = nil;
    dispatch_sync(_lockQueue, ^{
        callToAction = [self->_nativeAd.callToAction copy];
    });
    return callToAction;
}

- (NSDecimalNumber *)starRating {
    return nil;
}

- (NSString *)store {
    return nil;
}

- (NSString *)price {
    return nil;
}

#pragma mark - GADMediatedNativeAdDelegate

- (void)mediatedNativeAd:(id<GADMediatedNativeAd>)mediatedNativeAd
         didRenderInView:(UIView *)view
          viewController:(UIViewController *)viewController {
    NSMutableArray *assets = [[NSMutableArray alloc] init];
    if ([view isKindOfClass:[GADNativeAppInstallAdView class]]) {
        GADNativeAppInstallAdView *adView = (GADNativeAppInstallAdView *)view;
        if (adView.headlineView != nil) {
            [assets addObject:adView.headlineView];
        }
        if (adView.imageView != nil) {
            [assets addObject:adView.imageView];
        }
        if (adView.iconView != nil) {
            [assets addObject:adView.iconView];
        }
        if (adView.adChoicesView != nil) {
            [assets addObject:adView.adChoicesView];
        }
        if (adView.bodyView != nil) {
            [assets addObject:adView.bodyView];
        }
        if (adView.callToActionView != nil) {
            [assets addObject:adView.callToActionView];
        }
        if (adView.priceView != nil) {
            [assets addObject:adView.priceView];
        }
        if (adView.starRatingView != nil) {
            [assets addObject:adView.starRatingView];
        }
        if (adView.storeView != nil) {
            [assets addObject:adView.storeView];
        }
        if (adView.mediaView != nil) {
            [assets addObject:adView.mediaView];
        }
    } else {
        NSLog(@"View is not the instance of GADNativeAppInstallAdView, Failed to register View for "
              @"user interaction");
    }
    
    [_nativeAd registerViewForInteraction:view
                       withViewController:viewController
                       withClickableViews:assets];
}

- (void)mediatedNativeAd:(id<GADMediatedNativeAd>)mediatedNativeAd didUntrackView:(UIView *)view {
    [_nativeAd unregisterView];
}

#pragma mark - DUNativeAdDelegate

- (void)nativeAdDidLoad:(DUNativeAd *)nativeAd {
    [self loadNativeAdImages];
}

- (void)nativeAdWillLogImpression:(DUNativeAd *)nativeAd {
    if (_impressionLogged) {
        GADDU_LOG(@"DUNativeAd is trying to log an impression again. Adapter will ignore duplicate "
                  "impression pings.");
        return;
    }
    
    _impressionLogged = YES;
    [GADMediatedNativeAdNotificationSource mediatedNativeAdDidRecordImpression:self];
}

- (void)nativeAd:(DUNativeAd *)nativeAd didFailWithError:(NSError *)error {
    id<GADMAdNetworkConnector> strongConnector = _connector;
    id<GADMAdNetworkAdapter> strongAdapter = _adapter;
    [strongConnector adapter:strongAdapter didFailAd:error];
}

- (void)nativeAdDidClick:(DUNativeAd *)nativeAd {
    [GADMediatedNativeAdNotificationSource mediatedNativeAdDidRecordClick:self];
}

- (void)nativeAdDidFinishHandlingClick:(DUNativeAd *)nativeAd {
    // Do nothing.
}

@end
