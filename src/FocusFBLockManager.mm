#import "FocusFBLockManager.h"
#import "FocusFBPrefs.h"
#import "FocusFBTabManager.h"
#import "FocusFBSettingsViewController.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>

#if __has_include(<CoreNFC/CoreNFC.h>)
#import <CoreNFC/CoreNFC.h>
#define FFB_HAS_CORENFC_SDK 1
#else
#define FFB_HAS_CORENFC_SDK 0
#endif

NSString *const FocusFBLockStateDidChangeNotification = @"FocusFBLockStateDidChangeNotification";

static NSString *const kFFBKeychainService = @"com.focusfb.foqoslock.v2";
static NSString *const kFFBKeychainAccount = @"lockstate";
static NSString *const kFFBMirrorDefaultsKey = @"com.focusfb.foqoslock.v2.mirror";
static NSInteger const kFFBTimerPillTag = 0xFFBF09;
static NSInteger const kFFBMonthlyEmergencyLimit = 3;

static NSString *FFBCurrentMonthKey(void) {
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    df.timeZone = [NSTimeZone localTimeZone];
    df.dateFormat = @"yyyy-MM";
    return [df stringFromDate:[NSDate date]];
}

// ─────────────────────────────────────────────────────────────────────────────
// Crittografia SHA-256 + Generatore Token Casuale
// ─────────────────────────────────────────────────────────────────────────────

static NSString *FFBSHA256Hex(NSString *raw) {
    if (raw.length == 0) return @"";
    NSString *salted = [NSString stringWithFormat:@"FocusFB_PhysicalKey_v2::%@", raw];
    NSData *data = [salted dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex copy];
}

static NSString *FFBGenerateRandomSecretToken(void) {
    uint8_t bytes[16];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != errSecSuccess) {
        for (size_t i = 0; i < sizeof(bytes); i++) {
            bytes[i] = (uint8_t)arc4random_uniform(256);
        }
    }
    NSMutableString *hex = [NSMutableString stringWithString:@"FOCUSFB://KEY/"];
    for (size_t i = 0; i < sizeof(bytes); i++) {
        [hex appendFormat:@"%02X", bytes[i]];
    }
    return [hex copy];
}

static NSString *FFBTodayDateKey(void) {
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    df.timeZone = [NSTimeZone localTimeZone];
    df.dateFormat = @"yyyy-MM-dd";
    return [df stringFromDate:[NSDate date]];
}

static NSString *FFBFormatDuration(NSTimeInterval seconds) {
    NSInteger s = MAX(0, (NSInteger)ceil(seconds));
    NSInteger hrs = s / 3600;
    NSInteger mins = (s % 3600) / 60;
    NSInteger secs = s % 60;
    if (hrs > 0) {
        return [NSString stringWithFormat:@"%02ld:%02ld:%02ld", (long)hrs, (long)mins, (long)secs];
    }
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)mins, (long)secs];
}

// ─────────────────────────────────────────────────────────────────────────────
// Persistenza Keychain + NSUserDefaults Mirror (anti-tamper / anti-reinstall)
// ─────────────────────────────────────────────────────────────────────────────

static NSDictionary *FFBReadKeychainDict(void) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kFFBKeychainService,
        (__bridge id)kSecAttrAccount: kFFBKeychainAccount,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecSuccess && result != NULL) {
        NSData *data = (__bridge_transfer NSData *)result;
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([dict isKindOfClass:[NSDictionary class]]) {
            return dict;
        }
    }
    return nil;
}

static void FFBWriteKeychainDict(NSDictionary *dict) {
    if (!dict) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (!data) return;

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kFFBKeychainService,
        (__bridge id)kSecAttrAccount: kFFBKeychainAccount
    };
    NSDictionary *attrs = @{
        (__bridge id)kSecValueData: data,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    };
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attrs);
    if (status == errSecItemNotFound) {
        NSMutableDictionary *addQuery = [query mutableCopy];
        [addQuery addEntriesFromDictionary:attrs];
        SecItemAdd((__bridge CFDictionaryRef)addQuery, NULL);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. Scanner Fotocamera QR / Codice a Barre (AVFoundation)
// ─────────────────────────────────────────────────────────────────────────────

typedef NS_ENUM(NSInteger, FFBScannerMode) {
    FFBScannerModeRegisterDoubleScan = 0, // Scansiona 2 volte per registrare
    FFBScannerModeVerifySingle       = 1, // Verifica contro un hash atteso
};

@interface FFBBarcodeScannerViewController : UIViewController <AVCaptureMetadataOutputObjectsDelegate>
@property (nonatomic, assign) FFBScannerMode mode;
@property (nonatomic, copy, nullable) NSString *expectedHash;
@property (nonatomic, copy, nullable) NSString *customPrompt;
@property (nonatomic, copy, nullable) void (^onFinished)(BOOL success, NSString * _Nullable confirmedRawPayload);
@end

@implementation FFBBarcodeScannerViewController {
    AVCaptureSession *_session;
    AVCaptureVideoPreviewLayer *_previewLayer;
    UILabel *_promptLabel;
    UIView *_reticleView;
    UIButton *_torchButton;
    NSString *_firstScanPayload;
    BOOL _cooldownBetweenScans;
    BOOL _completed;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    // Top bar
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [closeBtn setTitle:FFBLoc(@"Cancel") forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    closeBtn.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.82];
    closeBtn.layer.cornerRadius = 18.0;
    closeBtn.contentEdgeInsets = UIEdgeInsetsMake(8, 16, 8, 16);
    closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [closeBtn addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];

    _torchButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_torchButton setImage:[UIImage systemImageNamed:@"flashlight.off.fill"] forState:UIControlStateNormal];
    _torchButton.tintColor = [UIColor whiteColor];
    _torchButton.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.82];
    _torchButton.layer.cornerRadius = 20.0;
    _torchButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_torchButton addTarget:self action:@selector(toggleTorch) forControlEvents:UIControlEventTouchUpInside];

    // Mirino centrale
    _reticleView = [[UIView alloc] init];
    _reticleView.translatesAutoresizingMaskIntoConstraints = NO;
    _reticleView.layer.borderColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.45 alpha:0.95].CGColor;
    _reticleView.layer.borderWidth = 3.0;
    _reticleView.layer.cornerRadius = 22.0;
    _reticleView.backgroundColor = [UIColor clearColor];

    // Box istruzioni in basso
    UIView *promptBox = [[UIView alloc] init];
    promptBox.translatesAutoresizingMaskIntoConstraints = NO;
    promptBox.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.88];
    promptBox.layer.cornerRadius = 18.0;

    _promptLabel = [[UILabel alloc] init];
    _promptLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _promptLabel.textColor = [UIColor whiteColor];
    _promptLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _promptLabel.textAlignment = NSTextAlignmentCenter;
    _promptLabel.numberOfLines = 0;
    if (self.customPrompt.length > 0) {
        _promptLabel.text = self.customPrompt;
    } else {
        _promptLabel.text = (self.mode == FFBScannerModeRegisterDoubleScan)
            ? FFBLoc(@"Lock.ScanStep1")
            : FFBLoc(@"Lock.ScanUnlockPrompt");
    }
    [promptBox addSubview:_promptLabel];

    [self.view addSubview:_reticleView];
    [self.view addSubview:promptBox];
    [self.view addSubview:closeBtn];
    [self.view addSubview:_torchButton];

    [NSLayoutConstraint activateConstraints:@[
        [closeBtn.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:14],
        [closeBtn.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],

        [_torchButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:14],
        [_torchButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_torchButton.widthAnchor constraintEqualToConstant:40],
        [_torchButton.heightAnchor constraintEqualToConstant:40],

        [_reticleView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_reticleView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-24],
        [_reticleView.widthAnchor constraintEqualToConstant:250],
        [_reticleView.heightAnchor constraintEqualToConstant:250],

        [promptBox.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [promptBox.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [promptBox.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-24],

        [_promptLabel.topAnchor constraintEqualToAnchor:promptBox.topAnchor constant:16],
        [_promptLabel.bottomAnchor constraintEqualToAnchor:promptBox.bottomAnchor constant:-16],
        [_promptLabel.leadingAnchor constraintEqualToAnchor:promptBox.leadingAnchor constant:16],
        [_promptLabel.trailingAnchor constraintEqualToAnchor:promptBox.trailingAnchor constant:-16],
    ]];

    [self checkPermissionAndStartCamera];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (_previewLayer) {
        _previewLayer.frame = self.view.bounds;
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopCamera];
}

- (void)checkPermissionAndStartCamera {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (status == AVAuthorizationStatusAuthorized) {
        [self setupCaptureSession];
    } else if (status == AVAuthorizationStatusNotDetermined) {
        __weak FFBBarcodeScannerViewController *weakScanner = self;
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                FFBBarcodeScannerViewController *strongScanner = weakScanner;
                if (!strongScanner) return;
                if (granted) {
                    [strongScanner setupCaptureSession];
                } else {
                    strongScanner->_promptLabel.text = @"Permesso fotocamera negato nelle Impostazioni di iOS.";
                }
            });
        }];
    } else {
        _promptLabel.text = @"Abilita l'accesso alla Fotocamera per Facebook in Impostazioni iOS.";
    }
}

- (void)setupCaptureSession {
    if (_session) return;
    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (!device) {
        _promptLabel.text = @"Fotocamera non disponibile su questo dispositivo.";
        return;
    }

    NSError *err = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&err];
    if (!input || ![session canAddInput:input]) {
        _promptLabel.text = err.localizedDescription ?: @"Errore apertura fotocamera.";
        return;
    }
    [session addInput:input];

    AVCaptureMetadataOutput *output = [[AVCaptureMetadataOutput alloc] init];
    if ([session canAddOutput:output]) {
        [session addOutput:output];
        [output setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
        NSMutableArray<AVMetadataObjectType> *supported = [NSMutableArray array];
        NSArray<AVMetadataObjectType> *desired = @[
            AVMetadataObjectTypeQRCode,
            AVMetadataObjectTypeEAN13Code,
            AVMetadataObjectTypeEAN8Code,
            AVMetadataObjectTypeUPCECode,
            AVMetadataObjectTypeCode128Code,
            AVMetadataObjectTypeCode39Code,
            AVMetadataObjectTypeCode93Code,
            AVMetadataObjectTypeITF14Code,
            AVMetadataObjectTypeDataMatrixCode,
            AVMetadataObjectTypePDF417Code,
            AVMetadataObjectTypeAztecCode
        ];
        for (AVMetadataObjectType type in desired) {
            if ([output.availableMetadataObjectTypes containsObject:type]) {
                [supported addObject:type];
            }
        }
        output.metadataObjectTypes = supported;
    }

    AVCaptureVideoPreviewLayer *preview = [AVCaptureVideoPreviewLayer layerWithSession:session];
    preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
    preview.frame = self.view.bounds;
    [self.view.layer insertSublayer:preview atIndex:0];

    _session = session;
    _previewLayer = preview;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [session startRunning];
    });
}

- (void)stopCamera {
    AVCaptureSession *session = _session;
    _session = nil;
    if (session) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (session.isRunning) {
                [session stopRunning];
            }
        });
    }
}

- (void)toggleTorch {
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (!device.hasTorch) return;
    if ([device lockForConfiguration:nil]) {
        BOOL turnOn = (device.torchMode != AVCaptureTorchModeOn);
        device.torchMode = turnOn ? AVCaptureTorchModeOn : AVCaptureTorchModeOff;
        [_torchButton setImage:[UIImage systemImageNamed:(turnOn ? @"flashlight.on.fill" : @"flashlight.off.fill")]
                      forState:UIControlStateNormal];
        [device unlockForConfiguration];
    }
}

- (void)captureOutput:(AVCaptureOutput *)output
didOutputMetadataObjects:(NSArray<__kindof AVMetadataObject *> *)metadataObjects
       fromConnection:(AVCaptureConnection *)connection {
    if (_completed || _cooldownBetweenScans) return;

    NSString *scannedValue = nil;
    for (AVMetadataObject *obj in metadataObjects) {
        if ([obj isKindOfClass:[AVMetadataMachineReadableCodeObject class]]) {
            AVMetadataMachineReadableCodeObject *readable = (AVMetadataMachineReadableCodeObject *)obj;
            if (readable.stringValue.length > 0) {
                scannedValue = [readable.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                break;
            }
        }
    }
    if (scannedValue.length == 0) return;

    if (self.mode == FFBScannerModeRegisterDoubleScan) {
        _completed = YES;
        UINotificationFeedbackGenerator *gen = [[UINotificationFeedbackGenerator alloc] init];
        [gen notificationOccurred:UINotificationFeedbackTypeSuccess];
        _reticleView.layer.borderColor = [UIColor systemGreenColor].CGColor;
        [self stopCamera];

        NSString *payload = [scannedValue copy];
        void (^cb)(BOOL, NSString *) = self.onFinished;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self dismissViewControllerAnimated:YES completion:^{
                if (cb) cb(YES, payload);
            }];
        });
        return;
    }

    // Modalità verifica singola contro hash salvato
    NSString *candidateHash = FFBSHA256Hex(scannedValue);
    if (self.expectedHash.length > 0 && [candidateHash isEqualToString:self.expectedHash]) {
        _completed = YES;
        UINotificationFeedbackGenerator *gen = [[UINotificationFeedbackGenerator alloc] init];
        [gen notificationOccurred:UINotificationFeedbackTypeSuccess];
        _reticleView.layer.borderColor = [UIColor systemGreenColor].CGColor;
        [self stopCamera];

        void (^cb)(BOOL, NSString *) = self.onFinished;
        [self dismissViewControllerAnimated:YES completion:^{
            if (cb) cb(YES, scannedValue);
        }];
    } else {
        _cooldownBetweenScans = YES;
        UINotificationFeedbackGenerator *gen = [[UINotificationFeedbackGenerator alloc] init];
        [gen notificationOccurred:UINotificationFeedbackTypeError];
        _reticleView.layer.borderColor = [UIColor systemRedColor].CGColor;
        _promptLabel.text = FFBLoc(@"Lock.ScanMismatch");

        __weak FFBBarcodeScannerViewController *weakScanner = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            FFBBarcodeScannerViewController *strongScanner = weakScanner;
            if (strongScanner) {
                strongScanner->_cooldownBetweenScans = NO;
                strongScanner->_reticleView.layer.borderColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.45 alpha:0.95].CGColor;
                strongScanner->_promptLabel.text = strongScanner.customPrompt ?: FFBLoc(@"Lock.ScanUnlockPrompt");
            }
        });
    }
}

- (void)cancelTapped {
    _completed = YES;
    [self stopCamera];
    void (^cb)(BOOL, NSString *) = self.onFinished;
    [self dismissViewControllerAnimated:YES completion:^{
        if (cb) cb(NO, nil);
    }];
}

@end

// ─────────────────────────────────────────────────────────────────────────────
// 2. Generatore QR Segreto Crittografico (CoreImage CIQRCodeGenerator)
// ─────────────────────────────────────────────────────────────────────────────

@interface FFBQRGeneratorViewController : UIViewController
@property (nonatomic, copy) NSString *secretPayload;
@property (nonatomic, copy, nullable) void (^onVerifiedAndSaved)(BOOL saved, NSString * _Nullable payload);
@end

@implementation FFBQRGeneratorViewController {
    UIImage *_qrImage;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.title = FFBLoc(@"Lock.GenerateSecretQR");
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                             target:self
                             action:@selector(cancelTapped)];

    if (self.secretPayload.length == 0) {
        self.secretPayload = FFBGenerateRandomSecretToken();
    }
    _qrImage = [self generateSharpQRImageForString:self.secretPayload];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];

    UILabel *info = [[UILabel alloc] init];
    info.numberOfLines = 0;
    info.textAlignment = NSTextAlignmentCenter;
    info.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    info.textColor = [UIColor secondaryLabelColor];
    info.text = FFBIsItalianLocale()
        ? @"1. Condividi o stampa questo codice QR unico e conservalo lontano da dove usi il telefono (es. un'altra stanza, garage o PC).\n2. Poi premi \"Verifica con Fotocamera\" per confermare che riesci a scansionarlo: solo dopo la verifica verrà salvato come chiave."
        : @"1. Print or send this unique QR code to another device kept away from your desk/couch.\n2. Tap \"Verify with Camera\" and scan it once to prove you saved it before locking.";

    UIView *qrCard = [[UIView alloc] init];
    qrCard.backgroundColor = [UIColor whiteColor];
    qrCard.layer.cornerRadius = 22.0;
    qrCard.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *qrView = [[UIImageView alloc] initWithImage:_qrImage];
    qrView.contentMode = UIViewContentModeScaleAspectFit;
    qrView.translatesAutoresizingMaskIntoConstraints = NO;
    [qrCard addSubview:qrView];

    UIButton *shareBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [shareBtn setTitle:(FFBIsItalianLocale() ? @"Condividi / Stampa / Salva QR" : @"Share / Print / Save QR") forState:UIControlStateNormal];
    [shareBtn setImage:[UIImage systemImageNamed:@"square.and.arrow.up"] forState:UIControlStateNormal];
    shareBtn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    shareBtn.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    shareBtn.layer.cornerRadius = 14.0;
    shareBtn.contentEdgeInsets = UIEdgeInsetsMake(13, 20, 13, 20);
    [shareBtn addTarget:self action:@selector(shareTapped) forControlEvents:UIControlEventTouchUpInside];

    UIButton *verifyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [verifyBtn setTitle:(FFBIsItalianLocale() ? @"Ho salvato il QR → Verifica con Fotocamera" : @"I Saved the QR → Verify with Camera")
               forState:UIControlStateNormal];
    verifyBtn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    [verifyBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    verifyBtn.backgroundColor = [UIColor colorWithRed:0.09 green:0.47 blue:0.95 alpha:1.0];
    verifyBtn.layer.cornerRadius = 14.0;
    verifyBtn.contentEdgeInsets = UIEdgeInsetsMake(15, 20, 15, 20);
    [verifyBtn addTarget:self action:@selector(verifyTapped) forControlEvents:UIControlEventTouchUpInside];

    [stack addArrangedSubview:info];
    [stack addArrangedSubview:qrCard];
    [stack addArrangedSubview:shareBtn];
    [stack addArrangedSubview:verifyBtn];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-30],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:22],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-22],

        [qrCard.widthAnchor constraintEqualToConstant:250],
        [qrCard.heightAnchor constraintEqualToConstant:250],
        [qrView.topAnchor constraintEqualToAnchor:qrCard.topAnchor constant:18],
        [qrView.bottomAnchor constraintEqualToAnchor:qrCard.bottomAnchor constant:-18],
        [qrView.leadingAnchor constraintEqualToAnchor:qrCard.leadingAnchor constant:18],
        [qrView.trailingAnchor constraintEqualToAnchor:qrCard.trailingAnchor constant:-18],

        [shareBtn.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [verifyBtn.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    ]];
}

- (UIImage *)generateSharpQRImageForString:(NSString *)str {
    NSData *data = [str dataUsingEncoding:NSUTF8StringEncoding];
    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setValue:data forKey:@"inputMessage"];
    [filter setValue:@"H" forKey:@"inputCorrectionLevel"];
    CIImage *ciImg = filter.outputImage;
    if (!ciImg) return nil;
    CIImage *scaled = [ciImg imageByApplyingTransform:CGAffineTransformMakeScale(16.0, 16.0)];
    CIContext *ctx = [CIContext contextWithOptions:nil];
    CGImageRef cgImg = [ctx createCGImage:scaled fromRect:scaled.extent];
    if (!cgImg) return nil;
    UIImage *img = [UIImage imageWithCGImage:cgImg];
    CGImageRelease(cgImg);
    return img;
}

- (void)shareTapped {
    if (!_qrImage) return;
    UIActivityViewController *act = [[UIActivityViewController alloc]
        initWithActivityItems:@[_qrImage]
        applicationActivities:nil];
    if (act.popoverPresentationController) {
        act.popoverPresentationController.sourceView = self.view;
        act.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    }
    [self presentViewController:act animated:YES completion:nil];
}

- (void)verifyTapped {
    NSString *expectedHash = FFBSHA256Hex(self.secretPayload);
    NSString *secretCopy = [self.secretPayload copy];

    FFBBarcodeScannerViewController *scanner = [[FFBBarcodeScannerViewController alloc] init];
    scanner.modalPresentationStyle = UIModalPresentationFullScreen;
    scanner.mode = FFBScannerModeVerifySingle;
    scanner.expectedHash = expectedHash;
    scanner.customPrompt = FFBIsItalianLocale()
        ? @"Ora inquadra il QR che hai appena stampato o inviato ad altro schermo per confermare"
        : @"Now scan your printed/saved QR code to confirm it works";

    __weak FFBQRGeneratorViewController *weakQR = self;
    scanner.onFinished = ^(BOOL success, NSString * _Nullable raw) {
        if (!success) return;
        FFBQRGeneratorViewController *strongQR = weakQR;
        if (!strongQR) return;
        void (^cb)(BOOL, NSString *) = strongQR.onVerifiedAndSaved;
        [strongQR dismissViewControllerAnimated:YES completion:^{
            if (cb) cb(YES, secretCopy);
        }];
    };
    [self presentViewController:scanner animated:YES completion:nil];
}

- (void)cancelTapped {
    void (^cb)(BOOL, NSString *) = self.onVerifiedAndSaved;
    [self dismissViewControllerAnimated:YES completion:^{
        if (cb) cb(NO, nil);
    }];
}

@end

// ─────────────────────────────────────────────────────────────────────────────
// 3. Lettore Tag NFC Fisico (CoreNFC weak-linked)
// ─────────────────────────────────────────────────────────────────────────────

#if FFB_HAS_CORENFC_SDK
API_AVAILABLE(ios(13.0))
@interface FFBNFCReaderCoordinator : NSObject <NFCTagReaderSessionDelegate>
@property (nonatomic, strong, nullable) NFCTagReaderSession *session;
@property (nonatomic, copy, nullable) void (^completion)(BOOL ok, NSString * _Nullable uidPayload, BOOL entitlementMissing);
- (void)beginWithPrompt:(NSString *)prompt completion:(void (^)(BOOL ok, NSString * _Nullable uidPayload, BOOL entitlementMissing))completion;
@end

@implementation FFBNFCReaderCoordinator

- (void)beginWithPrompt:(NSString *)prompt completion:(void (^)(BOOL ok, NSString * _Nullable uidPayload, BOOL entitlementMissing))completion {
    self.completion = completion;
    if ([NFCTagReaderSession class] == nil || ![NFCTagReaderSession readingAvailable]) {
        if (completion) completion(NO, nil, YES);
        return;
    }

    @try {
        NFCPollingOption opts = (NFCPollingISO14443 | NFCPollingISO15693);
        NFCTagReaderSession *s = [[NFCTagReaderSession alloc] initWithPollingOption:opts delegate:self queue:dispatch_get_main_queue()];
        if (!s) {
            if (completion) completion(NO, nil, YES);
            return;
        }
        s.alertMessage = prompt;
        self.session = s;
        [s beginSession];
    } @catch (__unused NSException *ex) {
        self.session = nil;
        self.completion = nil;
        if (completion) completion(NO, nil, YES);
    }
}

- (void)tagReaderSessionDidBecomeActive:(NFCTagReaderSession *)session {
    (void)session;
}

- (void)tagReaderSession:(NFCTagReaderSession *)session didInvalidateWithError:(NSError *)error {
    self.session = nil;
    void (^cb)(BOOL, NSString *, BOOL) = self.completion;
    self.completion = nil;
    if (!cb) return;

    // 200 = NFCReaderSessionInvalidationErrorUserCanceled
    if (error.code == 200) {
        cb(NO, nil, NO);
        return;
    }
    NSString *desc = error.localizedDescription.lowercaseString ?: @"";
    BOOL missingEnt = (error.code == 202 ||
                       [desc containsString:@"entitlement"] ||
                       [desc containsString:@"missing"] ||
                       [desc containsString:@"privilege"] ||
                       [desc containsString:@"resource"]);
    cb(NO, nil, missingEnt);
}

- (void)tagReaderSession:(NFCTagReaderSession *)session didDetectTags:(NSArray<__kindof id<NFCTag>> *)tags {
    id<NFCTag> tag = tags.firstObject;
    if (!tag) return;

    NSData *uidData = nil;
    if ([tag respondsToSelector:@selector(asNFCMiFareTag)] && [tag asNFCMiFareTag]) {
        uidData = [tag asNFCMiFareTag].identifier;
    } else if ([tag respondsToSelector:@selector(asNFCISO15693Tag)] && [tag asNFCISO15693Tag]) {
        uidData = [tag asNFCISO15693Tag].identifier;
    } else if ([tag respondsToSelector:@selector(asNFCISO7816Tag)] && [tag asNFCISO7816Tag]) {
        uidData = [tag asNFCISO7816Tag].identifier;
    } else if ([tag respondsToSelector:@selector(asNFCFeliCaTag)] && [tag asNFCFeliCaTag]) {
        uidData = [tag asNFCFeliCaTag].currentIDm;
    }

    if (uidData.length == 0) {
        [session invalidateSessionWithErrorMessage:@"Tag NFC non supportato o UID non leggibile."];
        return;
    }

    const uint8_t *bytes = (const uint8_t *)uidData.bytes;
    NSMutableString *uidHex = [NSMutableString stringWithString:@"NFC-UID:"];
    for (NSUInteger i = 0; i < uidData.length; i++) {
        [uidHex appendFormat:@"%02X", bytes[i]];
    }

    void (^cb)(BOOL, NSString *, BOOL) = self.completion;
    self.completion = nil;
    session.alertMessage = FFBIsItalianLocale() ? @"Tag NFC rilevato" : @"NFC tag detected";
    [session invalidateSession];
    self.session = nil;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (cb) cb(YES, [uidHex copy], NO);
    });
}

@end
#endif

// ─────────────────────────────────────────────────────────────────────────────
// 4. Schermata Full-Screen Invalicabile di Fine Tempo (FFBLockWallViewController)
// ─────────────────────────────────────────────────────────────────────────────

@interface FFBLockWallViewController : UIViewController
- (void)refreshStats;
@end

@implementation FFBLockWallViewController {
    UILabel *_titleLabel;
    UILabel *_bodyLabel;
    UIView *_timerBox;
    UILabel *_countdownLabel;
    UILabel *_subStatsLabel;
    UIButton *_goMarketplaceButton;
    UIButton *_unlockButton;
    UIButton *_openSettingsButton;
    UIButton *_emergencyButton;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.05 green:0.06 blue:0.09 alpha:1.0];

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor colorWithRed:0.11 green:0.13 blue:0.18 alpha:1.0];
    card.layer.cornerRadius = 28.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.09].CGColor;
    [self.view addSubview:card];

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"hourglass.bottomhalf.filled"]];
    icon.tintColor = [UIColor colorWithRed:0.98 green:0.42 blue:0.34 alpha:1.0];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.translatesAutoresizingMaskIntoConstraints = NO;

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = [UIFont systemFontOfSize:23 weight:UIFontWeightBold];
    _titleLabel.textColor = [UIColor whiteColor];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.numberOfLines = 0;

    _bodyLabel = [[UILabel alloc] init];
    _bodyLabel.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightRegular];
    _bodyLabel.textColor = [UIColor colorWithWhite:0.77 alpha:1.0];
    _bodyLabel.textAlignment = NSTextAlignmentCenter;
    _bodyLabel.numberOfLines = 0;

    _timerBox = [[UIView alloc] init];
    _timerBox.translatesAutoresizingMaskIntoConstraints = NO;
    _timerBox.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.32];
    _timerBox.layer.cornerRadius = 18.0;

    UILabel *waitHeader = [[UILabel alloc] init];
    waitHeader.translatesAutoresizingMaskIntoConstraints = NO;
    waitHeader.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    waitHeader.textColor = [UIColor colorWithWhite:0.60 alpha:1.0];
    waitHeader.textAlignment = NSTextAlignmentCenter;
    waitHeader.text = [FFBLoc(@"Lock.WallRemainingWait") uppercaseString];

    _countdownLabel = [[UILabel alloc] init];
    _countdownLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _countdownLabel.font = [UIFont monospacedDigitSystemFontOfSize:36 weight:UIFontWeightBold];
    _countdownLabel.textColor = [UIColor whiteColor];
    _countdownLabel.textAlignment = NSTextAlignmentCenter;

    [_timerBox addSubview:waitHeader];
    [_timerBox addSubview:_countdownLabel];

    _subStatsLabel = [[UILabel alloc] init];
    _subStatsLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    _subStatsLabel.textColor = [UIColor colorWithWhite:0.60 alpha:1.0];
    _subStatsLabel.textAlignment = NSTextAlignmentCenter;
    _subStatsLabel.numberOfLines = 2;

    _goMarketplaceButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_goMarketplaceButton setImage:[UIImage systemImageNamed:@"bag.fill"] forState:UIControlStateNormal];
    [_goMarketplaceButton setTitle:[NSString stringWithFormat:@"  %@", FFBLoc(@"Lock.WallGoMarketplaceBtn")] forState:UIControlStateNormal];
    _goMarketplaceButton.tintColor = [UIColor whiteColor];
    [_goMarketplaceButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _goMarketplaceButton.titleLabel.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightBold];
    _goMarketplaceButton.backgroundColor = [UIColor colorWithRed:0.13 green:0.66 blue:0.38 alpha:1.0];
    _goMarketplaceButton.layer.cornerRadius = 16.0;
    _goMarketplaceButton.contentEdgeInsets = UIEdgeInsetsMake(14, 18, 14, 18);
    [_goMarketplaceButton addTarget:self action:@selector(goMarketplaceTapped) forControlEvents:UIControlEventTouchUpInside];

    _unlockButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_unlockButton setImage:[UIImage systemImageNamed:@"qrcode.viewfinder"] forState:UIControlStateNormal];
    [_unlockButton setTitle:[NSString stringWithFormat:@"  %@", FFBLoc(@"Lock.WallResumeBtn")] forState:UIControlStateNormal];
    _unlockButton.tintColor = [UIColor whiteColor];
    [_unlockButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _unlockButton.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightBold];
    _unlockButton.backgroundColor = [UIColor colorWithRed:0.14 green:0.46 blue:0.94 alpha:1.0];
    _unlockButton.layer.cornerRadius = 16.0;
    _unlockButton.contentEdgeInsets = UIEdgeInsetsMake(13, 18, 13, 18);
    [_unlockButton addTarget:self action:@selector(unlockResumeTapped) forControlEvents:UIControlEventTouchUpInside];

    _openSettingsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_openSettingsButton setImage:[UIImage systemImageNamed:@"slider.horizontal.3"] forState:UIControlStateNormal];
    [_openSettingsButton setTitle:[NSString stringWithFormat:@"  %@", FFBLoc(@"Lock.WallSettingsBtn")] forState:UIControlStateNormal];
    _openSettingsButton.tintColor = [UIColor colorWithWhite:0.86 alpha:1.0];
    [_openSettingsButton setTitleColor:[UIColor colorWithWhite:0.86 alpha:1.0] forState:UIControlStateNormal];
    _openSettingsButton.titleLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
    _openSettingsButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    _openSettingsButton.layer.cornerRadius = 14.0;
    _openSettingsButton.contentEdgeInsets = UIEdgeInsetsMake(11, 16, 11, 16);
    [_openSettingsButton addTarget:self action:@selector(unlockSettingsTapped) forControlEvents:UIControlEventTouchUpInside];

    _emergencyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_emergencyButton setImage:[UIImage systemImageNamed:@"exclamationmark.shield"] forState:UIControlStateNormal];
    _emergencyButton.tintColor = [UIColor colorWithRed:1.0 green:0.62 blue:0.28 alpha:1.0];
    [_emergencyButton setTitleColor:[UIColor colorWithRed:1.0 green:0.62 blue:0.28 alpha:1.0] forState:UIControlStateNormal];
    [_emergencyButton setTitleColor:[UIColor colorWithWhite:0.45 alpha:1.0] forState:UIControlStateDisabled];
    _emergencyButton.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    _emergencyButton.backgroundColor = [UIColor colorWithRed:1.0 green:0.55 blue:0.18 alpha:0.12];
    _emergencyButton.layer.cornerRadius = 12.0;
    _emergencyButton.contentEdgeInsets = UIEdgeInsetsMake(10, 14, 10, 14);
    [_emergencyButton addTarget:self action:@selector(emergencyTapped) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        icon, _titleLabel, _bodyLabel, _timerBox, _subStatsLabel,
        _goMarketplaceButton, _unlockButton, _openSettingsButton, _emergencyButton
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 11;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [icon.widthAnchor constraintEqualToConstant:42],
        [icon.heightAnchor constraintEqualToConstant:42],

        [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],

        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:22],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-20],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],

        [_timerBox.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [waitHeader.topAnchor constraintEqualToAnchor:_timerBox.topAnchor constant:11],
        [waitHeader.leadingAnchor constraintEqualToAnchor:_timerBox.leadingAnchor constant:12],
        [waitHeader.trailingAnchor constraintEqualToAnchor:_timerBox.trailingAnchor constant:-12],
        [_countdownLabel.topAnchor constraintEqualToAnchor:waitHeader.bottomAnchor constant:4],
        [_countdownLabel.bottomAnchor constraintEqualToAnchor:_timerBox.bottomAnchor constant:-12],
        [_countdownLabel.leadingAnchor constraintEqualToAnchor:_timerBox.leadingAnchor constant:12],
        [_countdownLabel.trailingAnchor constraintEqualToAnchor:_timerBox.trailingAnchor constant:-12],

        [_goMarketplaceButton.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [_unlockButton.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [_openSettingsButton.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [_emergencyButton.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    ]];

    [self refreshStats];
}

- (void)refreshStats {
    FocusFBLockManager *mgr = [FocusFBLockManager shared];
    BOOL alwaysBlocked = (mgr.sessionLimitMinutes == -1 && !mgr.isDailyLockedOut && mgr.cooldownRemainingSeconds <= 0.5);
    BOOL dailyHit = mgr.isDailyLockedOut;

    _goMarketplaceButton.hidden = NO;
    _timerBox.hidden = alwaysBlocked;

    if (alwaysBlocked) {
        _titleLabel.text = FFBLoc(@"Lock.WallExtraAlwaysTitle");
        _bodyLabel.text = FFBLoc(@"Lock.WallExtraAlwaysBody");
    } else {
        _titleLabel.text = dailyHit ? FFBLoc(@"Lock.WallExtraDailyTitle") : FFBLoc(@"Lock.WallExtraSessionTitle");
        _bodyLabel.text = FFBLoc(@"Lock.WallExtraBody");
    }

    NSTimeInterval waitSec = dailyHit
        ? MAX(mgr.secondsUntilMidnight, mgr.cooldownRemainingSeconds)
        : mgr.cooldownRemainingSeconds;
    _countdownLabel.text = FFBFormatDuration(waitSec);

    NSInteger usedMin = mgr.dailyUsedSeconds / 60;
    NSString *keyDesc = [mgr registeredKeyDescription];
    _subStatsLabel.text = [NSString stringWithFormat:@"%@: %ld min  •  %@",
                           FFBLoc(@"Lock.WallUsedToday"), (long)usedMin, keyDesc];

    NSString *sfIcon = (mgr.keyType == FFBPhysicalKeyTypeNFCTag) ? @"wave.3.right.circle.fill" : @"qrcode.viewfinder";
    [_unlockButton setImage:[UIImage systemImageNamed:sfIcon] forState:UIControlStateNormal];

    if (!mgr.emergencyUnlockEnabled) {
        _emergencyButton.hidden = YES;
    } else {
        _emergencyButton.hidden = NO;
        NSInteger rem = mgr.emergencyUnlocksRemainingThisMonth;
        NSInteger lim = mgr.monthlyEmergencyUnlockLimit;
        if (rem > 0) {
            _emergencyButton.enabled = YES;
            _emergencyButton.backgroundColor = [UIColor colorWithRed:1.0 green:0.55 blue:0.18 alpha:0.14];
            NSString *title = [NSString stringWithFormat:FFBLoc(@"Lock.EmergencyBtnFmt"), (long)rem, (long)lim];
            [_emergencyButton setTitle:[NSString stringWithFormat:@"  %@", title] forState:UIControlStateNormal];
        } else {
            _emergencyButton.enabled = NO;
            _emergencyButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.05];
            NSString *title = [NSString stringWithFormat:FFBLoc(@"Lock.EmergencyExhaustedFmt"), (long)lim];
            [_emergencyButton setTitle:[NSString stringWithFormat:@"  %@", title] forState:UIControlStateDisabled];
        }
    }
}

- (void)emergencyTapped {
    [[FocusFBLockManager shared] presentEmergencyUnlockPromptFrom:self onUnlocked:nil];
}

- (void)goMarketplaceTapped {
    [[FocusFBLockManager shared] switchToFreeMarketplaceFromLockWall];
}

- (void)unlockResumeTapped {
    FocusFBLockManager *mgr = [FocusFBLockManager shared];
    [mgr presentVerifyPhysicalKeyFrom:self reason:FFBLoc(@"Lock.ScanUnlockPrompt") completion:^(BOOL verified) {
        if (!verified) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[FocusFBLockManager shared] grantEmergencyFiveMinutes];
        });
    }];
}

- (void)unlockSettingsTapped {
    FocusFBLockManager *mgr = [FocusFBLockManager shared];
    [mgr presentVerifyPhysicalKeyFrom:self reason:FFBLoc(@"Lock.ScanUnlockPrompt") completion:^(BOOL verified) {
        if (!verified) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[FocusFBLockManager shared] grantEmergencyFiveMinutes];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.32 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [FocusFBSettingsViewController presentPreUnlockedFromTopController];
            });
        });
    }];
}

@end

// ─────────────────────────────────────────────────────────────────────────────
// 5. Implementazione Principale FocusFBLockManager
// ─────────────────────────────────────────────────────────────────────────────

@implementation FocusFBLockManager {
    BOOL _strictLockActive;
    FFBPhysicalKeyType _keyType;
    NSString *_keyHash;
    NSString *_keyLabel;
    uint64_t _stateRevision;

    FFBLockScope _lockScope;
    NSInteger _sessionLimitMinutes; // 0 = disattivato, -1 = sempre bloccato (0 min), >0 = minuti
    NSInteger _cooldownMinutes;
    NSInteger _dailyLimitMinutes;
    BOOL _showRemainingTimerPill;
    BOOL _emergencyUnlockEnabled;
    NSString *_emergencyMonthKey;
    NSInteger _emergencyUsedThisMonth;
    BOOL _pauseCountingForFocusFBUI;

    NSString *_usageDateKey;
    NSInteger _dailyUsedSeconds;
    NSInteger _sessionUsedSeconds;
    NSInteger _sessionBonusSeconds;
    NSInteger _dailyBonusSeconds;
    NSTimeInterval _lastActiveTimestamp;
    NSTimeInterval _cooldownUntilTimestamp;
    NSTimeInterval _marketplaceGraceUntil;
    BOOL _lastForceMarketplaceOnlyState;

    NSTimer *_heartbeatTimer;
    NSInteger _ticksSinceFlush;
    UIWindow *_lockWindow;
    FFBLockWallViewController *_lockWallVC;

#if FFB_HAS_CORENFC_SDK
    id _activeNFCCoordinator;
#endif
}

+ (instancetype)shared {
    static FocusFBLockManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[FocusFBLockManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lockScope = FFBLockScopeExceptMarketplace;
        _sessionLimitMinutes = -1; // Default: Feed/Reels bloccati, Marketplace sempre libero
        _cooldownMinutes = 30;
        _dailyLimitMinutes = 0;
        _showRemainingTimerPill = YES;
        _emergencyUnlockEnabled = YES;
        _emergencyMonthKey = FFBCurrentMonthKey();
        _emergencyUsedThisMonth = 0;
        _usageDateKey = FFBTodayDateKey();
        _marketplaceGraceUntil = [[NSDate date] timeIntervalSince1970] + 2.5;
        [self loadPersistedState];
        _lastForceMarketplaceOnlyState = self.shouldForceMarketplaceOnlyNow;
    }
    return self;
}

- (void)start {
    static dispatch_once_t startOnce;
    dispatch_once(&startOnce, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setupNotificationsAndTimer];
            [self refreshEnforcementUI];
        });
    });
}

- (void)setupNotificationsAndTimer {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(appDidBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(appWillResignActive) name:UIApplicationWillResignActiveNotification object:nil];
    [nc addObserver:self selector:@selector(appWillResignActive) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [nc addObserver:self selector:@selector(appWillResignActive) name:UIApplicationWillTerminateNotification object:nil];

    _heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                       target:self
                                                     selector:@selector(onHeartbeatTick)
                                                     userInfo:nil
                                                      repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_heartbeatTimer forMode:NSRunLoopCommonModes];
}

// ─────────────────────────────────────────────────────────────────────────────
// Caricamento / Salvataggio Tamper-Resistant (Keychain + NSUserDefaults)
// ─────────────────────────────────────────────────────────────────────────────

- (void)loadPersistedState {
    NSDictionary *kc = FFBReadKeychainDict();
    NSDictionary *ud = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kFFBMirrorDefaultsKey];

    NSDictionary *base = nil;
    if (kc && ud) {
        uint64_t revKC = [kc[@"rev"] unsignedLongLongValue];
        uint64_t revUD = [ud[@"rev"] unsignedLongLongValue];
        base = (revUD > revKC) ? ud : kc;
        _stateRevision = MAX(revKC, revUD);
    } else {
        base = kc ?: ud;
        _stateRevision = [base[@"rev"] unsignedLongLongValue];
    }
    if (!base) return;

    _strictLockActive = [base[@"strictLock"] boolValue];
    _keyType = (FFBPhysicalKeyType)[(base[@"keyType"] ?: @0) integerValue];
    _keyHash = [base[@"keyHash"] copy];
    _keyLabel = [base[@"keyLabel"] copy];

    if (_keyHash.length != 64 || _keyType == FFBPhysicalKeyTypeNone) {
        _keyType = FFBPhysicalKeyTypeNone;
        _strictLockActive = NO;
    }

    // v2.5+: Marketplace è SEMPRE escluso dal blocco Foqos (migra automaticamente vecchi stati salvati)
    _lockScope = FFBLockScopeExceptMarketplace;

    NSInteger rawSessionLimit = [(base[@"sessionLimitMinutes"] ?: @0) integerValue];
    _sessionLimitMinutes = (rawSessionLimit == -1) ? -1 : MAX(0, rawSessionLimit);
    _cooldownMinutes = MAX(1, [(base[@"cooldownMinutes"] ?: @30) integerValue]);
    _dailyLimitMinutes = [(base[@"dailyLimitMinutes"] ?: @0) integerValue];
    _showRemainingTimerPill = (base[@"showTimerPill"] != nil) ? [base[@"showTimerPill"] boolValue] : YES;
    _emergencyUnlockEnabled = (base[@"emergencyEnabled"] != nil) ? [base[@"emergencyEnabled"] boolValue] : YES;

    NSString *curMonth = FFBCurrentMonthKey();
    NSString *savedMonth = base[@"emergencyMonth"];
    _emergencyMonthKey = curMonth;
    if ([savedMonth isKindOfClass:NSString.class] && [savedMonth isEqualToString:curMonth]) {
        _emergencyUsedThisMonth = MAX(0, MIN(kFFBMonthlyEmergencyLimit, [base[@"emergencyUsed"] integerValue]));
    } else {
        _emergencyUsedThisMonth = 0;
    }

    _cooldownUntilTimestamp = [base[@"cooldownUntil"] doubleValue];
    _lastActiveTimestamp = [base[@"lastActive"] doubleValue];

    NSString *today = FFBTodayDateKey();
    NSString *savedDate = base[@"usageDate"];
    _usageDateKey = today;

    _dailyUsedSeconds = [savedDate isEqualToString:today] ? [base[@"dailyUsed"] integerValue] : 0;
    _dailyBonusSeconds = [savedDate isEqualToString:today] ? [base[@"dailyBonus"] integerValue] : 0;
    _sessionUsedSeconds = [base[@"sessionUsed"] integerValue];
    _sessionBonusSeconds = [(base[@"sessionBonus"] ?: @0) integerValue];

    if (!_strictLockActive) {
        _cooldownUntilTimestamp = 0;
        _sessionUsedSeconds = 0;
        _sessionBonusSeconds = 0;
    }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (_lastActiveTimestamp > 0 && (now - _lastActiveTimestamp) >= (_cooldownMinutes * 60.0) && now >= _cooldownUntilTimestamp) {
        _sessionUsedSeconds = 0;
        _sessionBonusSeconds = 0;
    }

    if (_strictLockActive && ![FocusFBPrefs shared].enabled) {
        [FocusFBPrefs shared].enabled = YES;
    }
}

- (void)saveStateNow {
    _stateRevision += 1;
    NSDictionary *payload = @{
        @"rev": @(_stateRevision),
        @"strictLock": @(_strictLockActive),
        @"keyType": @(_keyType),
        @"keyHash": _keyHash ?: @"",
        @"keyLabel": _keyLabel ?: @"",
        @"lockScope": @(_lockScope),
        @"sessionLimitMinutes": @(_sessionLimitMinutes),
        @"cooldownMinutes": @(_cooldownMinutes),
        @"dailyLimitMinutes": @(_dailyLimitMinutes),
        @"showTimerPill": @(_showRemainingTimerPill),
        @"emergencyEnabled": @(_emergencyUnlockEnabled),
        @"emergencyMonth": _emergencyMonthKey ?: FFBCurrentMonthKey(),
        @"emergencyUsed": @(_emergencyUsedThisMonth),
        @"usageDate": _usageDateKey ?: FFBTodayDateKey(),
        @"dailyUsed": @(_dailyUsedSeconds),
        @"sessionUsed": @(_sessionUsedSeconds),
        @"sessionBonus": @(_sessionBonusSeconds),
        @"dailyBonus": @(_dailyBonusSeconds),
        @"lastActive": @(_lastActiveTimestamp),
        @"cooldownUntil": @(_cooldownUntilTimestamp),
    };
    [[NSUserDefaults standardUserDefaults] setObject:payload forKey:kFFBMirrorDefaultsKey];
    FFBWriteKeychainDict(payload);
}

// ─────────────────────────────────────────────────────────────────────────────
// Proprietà e Calcolo Quota Tempo
// ─────────────────────────────────────────────────────────────────────────────

- (BOOL)strictLockActive { return _strictLockActive; }
- (FFBPhysicalKeyType)keyType { return _keyType; }
- (NSString *)keyLabel { return _keyLabel; }
- (BOOL)hasRegisteredKey { return (_keyType != FFBPhysicalKeyTypeNone && _keyHash.length == 64); }
- (NSInteger)sessionUsedSeconds { return _sessionUsedSeconds; }
- (NSInteger)dailyUsedSeconds { return _dailyUsedSeconds; }
- (BOOL)isLockWallVisible { return (_lockWindow != nil && !_lockWindow.hidden); }
- (BOOL)pauseCountingForFocusFBUI { return _pauseCountingForFocusFBUI; }
- (void)setPauseCountingForFocusFBUI:(BOOL)val {
    _pauseCountingForFocusFBUI = val;
    if (val) {
        _lastActiveTimestamp = [[NSDate date] timeIntervalSince1970];
    }
    [self refreshEnforcementUI];
}

- (FFBLockScope)lockScope { return FFBLockScopeExceptMarketplace; }
- (void)setLockScope:(__unused FFBLockScope)val {
    _lockScope = FFBLockScopeExceptMarketplace;
    [self saveStateNow];
    [self refreshEnforcementUI];
    [[NSNotificationCenter defaultCenter] postNotificationName:FocusFBLockStateDidChangeNotification object:self];
}

- (NSInteger)sessionLimitMinutes { return _sessionLimitMinutes; }
- (void)setSessionLimitMinutes:(NSInteger)val {
    _sessionLimitMinutes = (val == -1) ? -1 : MAX(0, val);
    _sessionUsedSeconds = 0;
    _sessionBonusSeconds = 0;
    _cooldownUntilTimestamp = 0;
    [self saveStateNow];
    [self refreshEnforcementUI];
    [[NSNotificationCenter defaultCenter] postNotificationName:FocusFBLockStateDidChangeNotification object:self];
}

- (NSInteger)cooldownMinutes { return _cooldownMinutes; }
- (void)setCooldownMinutes:(NSInteger)val {
    _cooldownMinutes = MAX(1, val);
    [self saveStateNow];
    [[NSNotificationCenter defaultCenter] postNotificationName:FocusFBLockStateDidChangeNotification object:self];
}

- (NSInteger)dailyLimitMinutes { return _dailyLimitMinutes; }
- (void)setDailyLimitMinutes:(NSInteger)val {
    _dailyLimitMinutes = MAX(0, val);
    [self saveStateNow];
    [self refreshEnforcementUI];
    [[NSNotificationCenter defaultCenter] postNotificationName:FocusFBLockStateDidChangeNotification object:self];
}

- (BOOL)showRemainingTimerPill { return _showRemainingTimerPill; }
- (void)setShowRemainingTimerPill:(BOOL)val {
    _showRemainingTimerPill = val;
    [self saveStateNow];
    [self refreshEnforcementUI];
}

- (BOOL)emergencyUnlockEnabled { return _emergencyUnlockEnabled; }
- (void)setEmergencyUnlockEnabled:(BOOL)val {
    _emergencyUnlockEnabled = val;
    [self saveStateNow];
    [self refreshEnforcementUI];
    [[NSNotificationCenter defaultCenter] postNotificationName:FocusFBLockStateDidChangeNotification object:self];
}

- (NSInteger)monthlyEmergencyUnlockLimit {
    return kFFBMonthlyEmergencyLimit;
}

- (NSInteger)emergencyUnlocksRemainingThisMonth {
    [self rolloverMidnightIfNeeded];
    return MAX(0, kFFBMonthlyEmergencyLimit - _emergencyUsedThisMonth);
}

- (void)rolloverMidnightIfNeeded {
    NSString *today = FFBTodayDateKey();
    NSString *curMonth = FFBCurrentMonthKey();
    BOOL changed = NO;

    if (![_usageDateKey isEqualToString:today]) {
        _usageDateKey = today;
        _dailyUsedSeconds = 0;
        _dailyBonusSeconds = 0;
        changed = YES;
    }
    if (![_emergencyMonthKey isEqualToString:curMonth]) {
        _emergencyMonthKey = curMonth;
        _emergencyUsedThisMonth = 0;
        changed = YES;
    }
    if (changed) {
        [self saveStateNow];
    }
}

- (NSTimeInterval)cooldownRemainingSeconds {
    if (!_strictLockActive || !self.hasRegisteredKey) return 0.0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    return MAX(0.0, _cooldownUntilTimestamp - now);
}

- (NSTimeInterval)secondsUntilMidnight {
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *now = [NSDate date];
    NSDate *tomorrow = [cal dateByAddingUnit:NSCalendarUnitDay value:1 toDate:now options:0];
    NSDate *startOfTomorrow = [cal startOfDayForDate:tomorrow];
    return MAX(0.0, [startOfTomorrow timeIntervalSinceDate:now]);
}

- (BOOL)isSessionLockedOut {
    if (!_strictLockActive || !self.hasRegisteredKey) return NO;
    if (self.cooldownRemainingSeconds > 0.5) return YES;
    if (_sessionLimitMinutes == -1) {
        NSInteger allowedBonus = _sessionBonusSeconds;
        return (_sessionUsedSeconds >= allowedBonus);
    }
    return NO;
}

- (BOOL)isDailyLockedOut {
    if (!_strictLockActive || !self.hasRegisteredKey) return NO;
    [self rolloverMidnightIfNeeded];
    if (_dailyLimitMinutes <= 0) return NO;
    NSInteger allowedDaily = _dailyLimitMinutes * 60 + _dailyBonusSeconds;
    return (_dailyUsedSeconds >= allowedDaily);
}

- (BOOL)isQuotaExhaustedNow {
    if (!_strictLockActive || !self.hasRegisteredKey) return NO;
    return (self.isSessionLockedOut || self.isDailyLockedOut);
}

- (BOOL)shouldForceMarketplaceOnlyNow {
    if (!_strictLockActive || !self.hasRegisteredKey) return NO;
    return self.isQuotaExhaustedNow;
}

- (BOOL)isTimeBlockedNow {
    if (!self.isQuotaExhaustedNow) return NO;
    if (_pauseCountingForFocusFBUI) return NO;

    // Marketplace è SEMPRE libero 24/7: il blocco Foqos agisce solo su Feed, Reels, Storie e sezioni social
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now < _marketplaceGraceUntil) return NO;
    if (FocusFBIsUserCurrentlyInMarketplace()) return NO;
    return YES;
}

- (NSTimeInterval)minimumRemainingActiveSeconds {
    if (!_strictLockActive || !self.hasRegisteredKey) return DBL_MAX;
    NSTimeInterval best = DBL_MAX;
    if (_sessionLimitMinutes == -1) {
        best = MIN(best, MAX(0.0, (NSTimeInterval)(_sessionBonusSeconds - _sessionUsedSeconds)));
    } else if (_sessionLimitMinutes > 0) {
        NSInteger allowedSess = _sessionLimitMinutes * 60 + _sessionBonusSeconds;
        best = MIN(best, MAX(0.0, (NSTimeInterval)(allowedSess - _sessionUsedSeconds)));
    }
    if (_dailyLimitMinutes > 0) {
        NSInteger allowedDaily = _dailyLimitMinutes * 60 + _dailyBonusSeconds;
        best = MIN(best, MAX(0.0, (NSTimeInterval)(allowedDaily - _dailyUsedSeconds)));
    }
    return best;
}

- (NSString *)formattedRemainingSummary {
    NSString *scopeTag = FFBLoc(@"Lock.ScopeExceptMPBadge");
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:scopeTag];

    if (_sessionLimitMinutes == -1) {
        if (_sessionBonusSeconds > _sessionUsedSeconds) {
            NSTimeInterval rem = MAX(0, _sessionBonusSeconds - _sessionUsedSeconds);
            [parts addObject:[NSString stringWithFormat:@"Extra: %@", FFBFormatDuration(rem)]];
        } else {
            [parts addObject:FFBLoc(@"Lock.AlwaysBlockedBadge")];
        }
    } else if (_sessionLimitMinutes > 0) {
        NSInteger allowed = _sessionLimitMinutes * 60 + _sessionBonusSeconds;
        NSTimeInterval rem = MAX(0, allowed - _sessionUsedSeconds);
        [parts addObject:[NSString stringWithFormat:@"%@: %@",
                          FFBIsItalianLocale() ? @"Sessione" : @"Session",
                          FFBFormatDuration(rem)]];
    }
    if (_dailyLimitMinutes > 0) {
        NSInteger allowed = _dailyLimitMinutes * 60 + _dailyBonusSeconds;
        NSTimeInterval rem = MAX(0, allowed - _dailyUsedSeconds);
        [parts addObject:[NSString stringWithFormat:@"%@: %@",
                          FFBIsItalianLocale() ? @"Oggi" : @"Today",
                          FFBFormatDuration(rem)]];
    }
    return [parts componentsJoinedByString:@" • "];
}

- (NSString *)registeredKeyDescription {
    if (!self.hasRegisteredKey) return FFBLoc(@"Lock.KeyNone");
    NSString *prefix = (_keyType == FFBPhysicalKeyTypeNFCTag) ? @"NFC" : @"QR / Barcode";
    if (_keyLabel.length > 0) {
        return [NSString stringWithFormat:@"%@ (%@)", prefix, _keyLabel];
    }
    return prefix;
}

- (void)switchToFreeMarketplaceFromLockWall {
    _marketplaceGraceUntil = [[NSDate date] timeIntervalSince1970] + 3.0;
    [self teardownLockWindow];
    [self updateTimerPillVisible:NO remaining:0];
    FocusFBForceSwitchToMarketplaceNow();
}

// ─────────────────────────────────────────────────────────────────────────────
// Heartbeat 1s e Ciclo Foreground / Background
// ─────────────────────────────────────────────────────────────────────────────

- (void)appDidBecomeActive {
    [self rolloverMidnightIfNeeded];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (_lastActiveTimestamp > 0 && (now - _lastActiveTimestamp) >= (_cooldownMinutes * 60.0) && now >= _cooldownUntilTimestamp) {
        _sessionUsedSeconds = 0;
        _sessionBonusSeconds = 0;
    }
    if (_strictLockActive && !self.hasRegisteredKey) {
        _strictLockActive = NO;
    }
    if (_strictLockActive && ![FocusFBPrefs shared].enabled) {
        [FocusFBPrefs shared].enabled = YES;
    }
    [self refreshEnforcementUI];
}

- (void)appWillResignActive {
    if (!self.isQuotaExhaustedNow) {
        _lastActiveTimestamp = [[NSDate date] timeIntervalSince1970];
    }
    [self saveStateNow];
}

- (void)onHeartbeatTick {
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        return;
    }

    if (!_strictLockActive) {
        if (_lockWindow) {
            [self refreshEnforcementUI];
        }
        return;
    }

    [self rolloverMidnightIfNeeded];

    if (!self.hasRegisteredKey) {
        _strictLockActive = NO;
        [self saveStateNow];
        [self refreshEnforcementUI];
        return;
    }

    if (![FocusFBPrefs shared].enabled) {
        [FocusFBPrefs shared].enabled = YES;
    }

    if (self.isQuotaExhaustedNow) {
        [self refreshEnforcementUI];
        return;
    }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    // Mentre l'utente è dentro le Impostazioni FocusFB o lo Scanner QR/NFC, non consumare i secondi
    if (_pauseCountingForFocusFBUI) {
        _lastActiveTimestamp = now;
        [self refreshEnforcementUI];
        return;
    }

    // Se l'ambito è "Tutto tranne Marketplace", dentro Marketplace il timer è IN PAUSA (Marketplace sempre libero!)
    if (_lockScope == FFBLockScopeExceptMarketplace && FocusFBIsUserCurrentlyInMarketplace()) {
        if (_lastActiveTimestamp > 0 && (now - _lastActiveTimestamp) >= (_cooldownMinutes * 60.0)) {
            _sessionUsedSeconds = 0;
            _sessionBonusSeconds = 0;
        }
        [self refreshEnforcementUI];
        return;
    }

    if (_lastActiveTimestamp > 0 && (now - _lastActiveTimestamp) >= (_cooldownMinutes * 60.0)) {
        _sessionUsedSeconds = 0;
        _sessionBonusSeconds = 0;
    }
    _lastActiveTimestamp = now;

    if (_sessionLimitMinutes != 0 || _dailyLimitMinutes > 0) {
        _sessionUsedSeconds += 1;
        _dailyUsedSeconds += 1;

        if (_sessionLimitMinutes == -1) {
            NSInteger allowedBonus = _sessionBonusSeconds;
            if (_sessionUsedSeconds >= allowedBonus) {
                _sessionUsedSeconds = 0;
                _sessionBonusSeconds = 0;
                [self saveStateNow];
                [self refreshEnforcementUI];
                [[NSNotificationCenter defaultCenter] postNotificationName:FocusFBLockStateDidChangeNotification object:self];
                return;
            }
        } else if (_sessionLimitMinutes > 0) {
            NSInteger allowedSession = _sessionLimitMinutes * 60 + _sessionBonusSeconds;
            if (_sessionUsedSeconds >= allowedSession) {
                _cooldownUntilTimestamp = now + (MAX(1, _cooldownMinutes) * 60.0);
                _sessionUsedSeconds = 0;
                _sessionBonusSeconds = 0;
                [self saveStateNow];
                [self refreshEnforcementUI];
                [[NSNotificationCenter defaultCenter] postNotificationName:FocusFBLockStateDidChangeNotification object:self];
                return;
            }
        }

        if (_dailyLimitMinutes > 0) {
            NSInteger allowedDaily = _dailyLimitMinutes * 60 + _dailyBonusSeconds;
            if (_dailyUsedSeconds >= allowedDaily) {
                [self saveStateNow];
                [self refreshEnforcementUI];
                [[NSNotificationCenter defaultCenter] postNotificationName:FocusFBLockStateDidChangeNotification object:self];
                return;
            }
        }

        _ticksSinceFlush += 1;
        if (_ticksSinceFlush >= 5) {
            _ticksSinceFlush = 0;
            [self saveStateNow];
        }
    }

    [self refreshEnforcementUI];
}

// ─────────────────────────────────────────────────────────────────────────────
// Finestra di Blocco Full-Screen + Pillola Timer Residuo
// ─────────────────────────────────────────────────────────────────────────────

- (nullable UIWindowScene *)activeWindowScene {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            (scene.activationState == UISceneActivationStateForegroundActive ||
             scene.activationState == UISceneActivationStateForegroundInactive)) {
            return (UIWindowScene *)scene;
        }
    }
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

- (void)pauseBackgroundMediaInMainWindow {
    UIWindow *mainWin = FocusFBActiveWindow();
    if (!mainWin) return;
    [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
}

- (void)teardownLockWindow {
    if (!_lockWindow) return;
    if (_lockWallVC.presentedViewController && !_lockWallVC.presentedViewController.isBeingDismissed) {
        [_lockWallVC dismissViewControllerAnimated:NO completion:nil];
    }
    _lockWindow.hidden = YES;
    _lockWindow.rootViewController = nil;
    if (@available(iOS 13.0, *)) {
        _lockWindow.windowScene = nil;
    }
    _lockWindow = nil;
    _lockWallVC = nil;

    UIWindow *fbWin = FocusFBActiveWindow();
    if (fbWin) {
        [fbWin makeKeyWindow];
    }
}

- (void)refreshEnforcementUI {
    BOOL currentForceMP = self.shouldForceMarketplaceOnlyNow;
    if (currentForceMP != _lastForceMarketplaceOnlyState) {
        _lastForceMarketplaceOnlyState = currentForceMP;
        FocusFBRefreshUIImmediately();
    }

    BOOL blocked = self.isTimeBlockedNow;

    if (blocked) {
        if (!_lockWindow) {
            UIWindowScene *scene = [self activeWindowScene];
            if (scene) {
                _lockWindow = [[UIWindow alloc] initWithWindowScene:scene];
            } else {
                _lockWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            }
            _lockWindow.windowLevel = UIWindowLevelNormal + 35.0;
            _lockWallVC = [[FFBLockWallViewController alloc] init];
            _lockWindow.rootViewController = _lockWallVC;
            _lockWindow.hidden = YES;
        }
        if (_lockWindow.hidden) {
            [self pauseBackgroundMediaInMainWindow];
            _lockWindow.hidden = NO;
            [_lockWindow makeKeyAndVisible];
        }
        [_lockWallVC refreshStats];
        [self updateTimerPillVisible:NO remaining:0];
    } else {
        if (_lockWindow) {
            [self teardownLockWindow];
        }

        NSTimeInterval minRem = [self minimumRemainingActiveSeconds];
        BOOL inFreeMarketplace = (_lockScope == FFBLockScopeExceptMarketplace && FocusFBIsUserCurrentlyInMarketplace());
        BOOL showPill = (_strictLockActive && _showRemainingTimerPill && minRem < DBL_MAX && !inFreeMarketplace);
        [self updateTimerPillVisible:showPill remaining:minRem];
    }
}

- (void)updateTimerPillVisible:(BOOL)visible remaining:(NSTimeInterval)remaining {
    UIWindow *win = FocusFBActiveWindow();
    if (!win) return;

    UILabel *pill = (UILabel *)[win viewWithTag:kFFBTimerPillTag];
    if (!visible) {
        if (pill) pill.hidden = YES;
        return;
    }

    if (!pill) {
        pill = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 86, 24)];
        pill.tag = kFFBTimerPillTag;
        pill.userInteractionEnabled = NO;
        pill.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightBold];
        pill.textAlignment = NSTextAlignmentCenter;
        pill.textColor = [UIColor whiteColor];
        pill.layer.cornerRadius = 12.0;
        pill.layer.masksToBounds = YES;
        [win addSubview:pill];
    }

    pill.hidden = NO;
    pill.text = FFBFormatDuration(remaining);

    if (remaining <= 45.0) {
        pill.backgroundColor = [UIColor colorWithRed:0.86 green:0.18 blue:0.20 alpha:0.90];
    } else if (remaining <= 120.0) {
        pill.backgroundColor = [UIColor colorWithRed:0.85 green:0.50 blue:0.08 alpha:0.88];
    } else {
        pill.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.74];
    }

    [pill sizeToFit];
    CGFloat w = MAX(76.0, CGRectGetWidth(pill.bounds) + 18.0);
    CGFloat topY = MAX(win.safeAreaInsets.top + 2.0, 48.0);
    pill.frame = CGRectMake(CGRectGetWidth(win.bounds) - w - 12.0, topY, w, 24.0);
    [win bringSubviewToFront:pill];
}

// ─────────────────────────────────────────────────────────────────────────────
// Gestione Blocco Rigoroso & Azioni Emergenza
// ─────────────────────────────────────────────────────────────────────────────

- (BOOL)enableStrictLockError:(NSString * _Nullable * _Nullable)errorOut {
    if (!self.hasRegisteredKey) {
        if (errorOut) *errorOut = FFBLoc(@"Lock.NeedKeyAlertBody");
        return NO;
    }
    _strictLockActive = YES;
    _lockScope = FFBLockScopeExceptMarketplace;
    if (_sessionLimitMinutes == 0 && _dailyLimitMinutes <= 0) {
        _sessionLimitMinutes = -1; // Blocca subito Feed/Reels lasciando Marketplace libero
    }
    _cooldownUntilTimestamp = 0;
    _sessionUsedSeconds = 0;
    _sessionBonusSeconds = 0;
    _lastActiveTimestamp = [[NSDate date] timeIntervalSince1970];
    [FocusFBPrefs shared].enabled = YES;
    [self saveStateNow];
    [self refreshEnforcementUI];
    [[NSNotificationCenter defaultCenter] postNotificationName:FocusFBLockStateDidChangeNotification object:self];
    return YES;
}

- (void)disableStrictLockAfterVerifiedScan {
    _strictLockActive = NO;
    _cooldownUntilTimestamp = 0;
    _sessionUsedSeconds = 0;
    _sessionBonusSeconds = 0;
    [self saveStateNow];
    [self refreshEnforcementUI];
    [[NSNotificationCenter defaultCenter] postNotificationName:FocusFBLockStateDidChangeNotification object:self];
}

- (BOOL)consumeEmergencyUnlockAndDisableLock {
    [self rolloverMidnightIfNeeded];
    if (!_emergencyUnlockEnabled) return NO;
    if (_emergencyUsedThisMonth >= kFFBMonthlyEmergencyLimit) return NO;

    _emergencyUsedThisMonth += 1;
    _strictLockActive = NO;
    _cooldownUntilTimestamp = 0;
    _sessionUsedSeconds = 0;
    _sessionBonusSeconds = 0;
    [self saveStateNow];
    [self refreshEnforcementUI];
    [[NSNotificationCenter defaultCenter] postNotificationName:FocusFBLockStateDidChangeNotification object:self];
    return YES;
}

- (void)presentEmergencyUnlockPromptFrom:(UIViewController *)presenter
                              onUnlocked:(void (^ _Nullable)(void))onUnlocked {
    if (!presenter) return;
    [self rolloverMidnightIfNeeded];
    NSInteger rem = self.emergencyUnlocksRemainingThisMonth;
    if (!_emergencyUnlockEnabled || rem <= 0) {
        return;
    }

    NSInteger afterUse = MAX(0, rem - 1);
    NSString *msg = [NSString stringWithFormat:FFBLoc(@"Lock.EmergencyConfirmBodyFmt"), (long)afterUse];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:FFBLoc(@"Lock.EmergencyConfirmTitle")
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:FFBLoc(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:FFBLoc(@"Lock.EmergencyConfirmAction")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *a) {
        if ([[FocusFBLockManager shared] consumeEmergencyUnlockAndDisableLock]) {
            NSInteger nowRem = [FocusFBLockManager shared].emergencyUnlocksRemainingThisMonth;
            NSInteger lim = [FocusFBLockManager shared].monthlyEmergencyUnlockLimit;
            NSString *toast = [NSString stringWithFormat:FFBLoc(@"Lock.EmergencyUsedToastFmt"), (long)nowRem, (long)lim];
            FocusFBShowToast(toast, @"lock.open.fill");
            if (onUnlocked) onUnlocked();
        }
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)grantEmergencyFiveMinutes {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    _cooldownUntilTimestamp = 0;
    _sessionUsedSeconds = 0;
    _sessionBonusSeconds = 0;
    if (_sessionLimitMinutes == -1) {
        _sessionBonusSeconds = 300;
    } else if (_sessionLimitMinutes > 0 && _sessionLimitMinutes < 5) {
        _sessionBonusSeconds = (5 - _sessionLimitMinutes) * 60;
    }
    if (_dailyLimitMinutes > 0) {
        NSInteger neededDaily = (_dailyUsedSeconds + 300) - (_dailyLimitMinutes * 60);
        if (neededDaily > _dailyBonusSeconds) {
            _dailyBonusSeconds = neededDaily;
        }
    }
    _lastActiveTimestamp = now;
    [self saveStateNow];
    [self refreshEnforcementUI];
    [[NSNotificationCenter defaultCenter] postNotificationName:FocusFBLockStateDidChangeNotification object:self];
}

- (void)resetTodayUsageAndCooldown {
    _cooldownUntilTimestamp = 0;
    _sessionUsedSeconds = 0;
    _sessionBonusSeconds = 0;
    _dailyUsedSeconds = 0;
    _dailyBonusSeconds = 0;
    _lastActiveTimestamp = [[NSDate date] timeIntervalSince1970];
    [self saveStateNow];
    [self refreshEnforcementUI];
    [[NSNotificationCenter defaultCenter] postNotificationName:FocusFBLockStateDidChangeNotification object:self];
}

// ─────────────────────────────────────────────────────────────────────────────
// Registrazione & Verifica Chiavi Fisiche (QR/Barcode, QR Segreto, NFC)
// ─────────────────────────────────────────────────────────────────────────────

- (void)promptLabelAndCommitKeyRaw:(NSString *)rawPayload
                              type:(FFBPhysicalKeyType)type
                      defaultLabel:(NSString *)defaultLabel
                         presenter:(UIViewController *)presenter
                        completion:(void (^ _Nullable)(BOOL))completion {
    NSString *hash = FFBSHA256Hex(rawPayload);
    // Salva immediatamente la chiave così anche se il popup nome viene chiuso è già registrata
    _keyType = type;
    _keyHash = [hash copy];
    _keyLabel = defaultLabel;
    [self saveStateNow];
    [[NSNotificationCenter defaultCenter] postNotificationName:FocusFBLockStateDidChangeNotification object:self];

    __weak FocusFBLockManager *weakSelf = self;
    __weak UIViewController *weakPresenter = presenter;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *strongPresenter = weakPresenter;
        if (!strongPresenter || strongPresenter.presentedViewController || strongPresenter.isBeingDismissed) {
            if (completion) completion(YES);
            return;
        }
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:FFBLoc(@"Lock.KeySavedTitle")
                             message:FFBLoc(@"Lock.KeyNamePrompt")
                      preferredStyle:UIAlertControllerStyleAlert];

        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = defaultLabel;
            tf.text = defaultLabel;
            tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];

        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            FocusFBLockManager *strongSelf = weakSelf;
            if (strongSelf) {
                NSString *entered = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                strongSelf->_keyLabel = (entered.length > 0) ? entered : defaultLabel;
                [strongSelf saveStateNow];
                [[NSNotificationCenter defaultCenter] postNotificationName:FocusFBLockStateDidChangeNotification object:strongSelf];
            }
            if (completion) completion(YES);
        }]];

        [strongPresenter presentViewController:alert animated:YES completion:nil];
    });
}

- (void)presentRegisterBarcodeOrQRFrom:(UIViewController *)presenter
                            completion:(void (^ _Nullable)(BOOL success))completion {
    FFBBarcodeScannerViewController *scanner = [[FFBBarcodeScannerViewController alloc] init];
    scanner.modalPresentationStyle = UIModalPresentationFullScreen;
    scanner.mode = FFBScannerModeRegisterDoubleScan;

    __weak FocusFBLockManager *weakSelf = self;
    __weak UIViewController *weakPresenter = presenter;
    scanner.onFinished = ^(BOOL success, NSString * _Nullable confirmedRawPayload) {
        if (!success || confirmedRawPayload.length == 0) {
            if (completion) completion(NO);
            return;
        }
        FocusFBLockManager *strongSelf = weakSelf;
        UIViewController *strongPresenter = weakPresenter;
        if (!strongSelf || !strongPresenter) return;
        NSString *defName = FFBIsItalianLocale() ? @"Codice Fisico" : @"Physical Code";
        [strongSelf promptLabelAndCommitKeyRaw:confirmedRawPayload
                                          type:FFBPhysicalKeyTypeBarcodeOrQR
                                  defaultLabel:defName
                                     presenter:strongPresenter
                                    completion:completion];
    };
    [presenter presentViewController:scanner animated:YES completion:nil];
}

- (void)presentGenerateSecretQRFrom:(UIViewController *)presenter
                         completion:(void (^ _Nullable)(BOOL success))completion {
    FFBQRGeneratorViewController *qrVC = [[FFBQRGeneratorViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:qrVC];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;

    __weak FocusFBLockManager *weakSelf = self;
    __weak UIViewController *weakPresenter = presenter;
    qrVC.onVerifiedAndSaved = ^(BOOL saved, NSString * _Nullable payload) {
        if (!saved || payload.length == 0) {
            if (completion) completion(NO);
            return;
        }
        FocusFBLockManager *strongSelf = weakSelf;
        UIViewController *strongPresenter = weakPresenter;
        if (!strongSelf || !strongPresenter) return;
        NSString *defName = FFBIsItalianLocale() ? @"QR Stampato FocusFB" : @"Printed FocusFB QR";
        [strongSelf promptLabelAndCommitKeyRaw:payload
                                          type:FFBPhysicalKeyTypeBarcodeOrQR
                                  defaultLabel:defName
                                     presenter:strongPresenter
                                    completion:completion];
    };
    [presenter presentViewController:nav animated:YES completion:nil];
}

- (void)showNFCUnavailableFallbackOn:(UIViewController *)presenter
                          completion:(void (^ _Nullable)(BOOL success))completion {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:FFBLoc(@"Lock.NFCUnavailableTitle")
                         message:FFBLoc(@"Lock.NFCUnavailableBody")
                  preferredStyle:UIAlertControllerStyleAlert];

    __weak FocusFBLockManager *weakSelf = self;
    __weak UIViewController *weakPresenter = presenter;
    [alert addAction:[UIAlertAction actionWithTitle:FFBLoc(@"Lock.RegisterQRBarcode")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) {
        FocusFBLockManager *strongSelf = weakSelf;
        UIViewController *strongPresenter = weakPresenter;
        if (strongSelf && strongPresenter) {
            [strongSelf presentRegisterBarcodeOrQRFrom:strongPresenter completion:completion];
        }
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:FFBLoc(@"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:^(__unused UIAlertAction *a) {
        if (completion) completion(NO);
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)presentRegisterNFCTagFrom:(UIViewController *)presenter
                       completion:(void (^ _Nullable)(BOOL success))completion {
#if FFB_HAS_CORENFC_SDK
    if (@available(iOS 13.0, *)) {
        FFBNFCReaderCoordinator *coord = [[FFBNFCReaderCoordinator alloc] init];
        _activeNFCCoordinator = coord;
        NSString *prompt = FFBIsItalianLocale()
            ? @"Avvicina il Tag NFC alla parte superiore dell'iPhone per registrarlo come chiave FocusFB."
            : @"Hold your NFC tag near the top of your iPhone to register it.";

        __weak FocusFBLockManager *weakSelf = self;
        __weak UIViewController *weakPresenter = presenter;
        [coord beginWithPrompt:prompt completion:^(BOOL ok, NSString * _Nullable uidPayload, BOOL entitlementMissing) {
            FocusFBLockManager *strongSelf = weakSelf;
            UIViewController *strongPresenter = weakPresenter;
            if (!strongSelf || !strongPresenter) return;
            strongSelf->_activeNFCCoordinator = nil;

            if (entitlementMissing) {
                [strongSelf showNFCUnavailableFallbackOn:strongPresenter completion:completion];
                return;
            }
            if (!ok || uidPayload.length == 0) {
                if (completion) completion(NO);
                return;
            }
            NSString *defName = @"Tag NFC";
            [strongSelf promptLabelAndCommitKeyRaw:uidPayload
                                              type:FFBPhysicalKeyTypeNFCTag
                                      defaultLabel:defName
                                         presenter:strongPresenter
                                        completion:completion];
        }];
        return;
    }
#endif
    [self showNFCUnavailableFallbackOn:presenter completion:completion];
}

- (void)presentVerifyPhysicalKeyFrom:(UIViewController *)presenter
                              reason:(nullable NSString *)reason
                          completion:(void (^)(BOOL verified))completion {
    if (!self.hasRegisteredKey) {
        if (completion) completion(YES);
        return;
    }

    if (_keyType == FFBPhysicalKeyTypeNFCTag) {
#if FFB_HAS_CORENFC_SDK
        if (@available(iOS 13.0, *)) {
            FFBNFCReaderCoordinator *coord = [[FFBNFCReaderCoordinator alloc] init];
            _activeNFCCoordinator = coord;
            NSString *expected = [_keyHash copy];
            NSString *prompt = reason ?: FFBLoc(@"Lock.ScanUnlockPrompt");

            __weak FocusFBLockManager *weakSelf = self;
            __weak UIViewController *weakPresenter = presenter;
            [coord beginWithPrompt:prompt completion:^(BOOL ok, NSString * _Nullable uidPayload, __unused BOOL entitlementMissing) {
                FocusFBLockManager *strongSelf = weakSelf;
                UIViewController *strongPresenter = weakPresenter;
                if (strongSelf) strongSelf->_activeNFCCoordinator = nil;

                if (!ok || uidPayload.length == 0) {
                    if (completion) completion(NO);
                    return;
                }
                if ([FFBSHA256Hex(uidPayload) isEqualToString:expected]) {
                    UINotificationFeedbackGenerator *gen = [[UINotificationFeedbackGenerator alloc] init];
                    [gen notificationOccurred:UINotificationFeedbackTypeSuccess];
                    if (completion) completion(YES);
                } else {
                    UINotificationFeedbackGenerator *gen = [[UINotificationFeedbackGenerator alloc] init];
                    [gen notificationOccurred:UINotificationFeedbackTypeError];
                    if (strongPresenter) {
                        NSString *errTitle = FFBIsItalianLocale() ? @"Chiave non valida" : @"Invalid key";
                        UIAlertController *err = [UIAlertController alertControllerWithTitle:errTitle
                                                                                     message:FFBLoc(@"Lock.ScanMismatch")
                                                                              preferredStyle:UIAlertControllerStyleAlert];
                        [err addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
                        [strongPresenter presentViewController:err animated:YES completion:nil];
                    }
                    if (completion) completion(NO);
                }
            }];
            return;
        }
#endif
        if (completion) completion(NO);
        return;
    }

    // Verifica tramite fotocamera QR / Codice a barre
    FFBBarcodeScannerViewController *scanner = [[FFBBarcodeScannerViewController alloc] init];
    scanner.modalPresentationStyle = UIModalPresentationFullScreen;
    scanner.mode = FFBScannerModeVerifySingle;
    scanner.expectedHash = [_keyHash copy];
    scanner.customPrompt = reason ?: FFBLoc(@"Lock.ScanUnlockPrompt");
    scanner.onFinished = ^(BOOL success, __unused NSString * _Nullable raw) {
        if (completion) completion(success);
    };
    [presenter presentViewController:scanner animated:YES completion:nil];
}

@end
