#import "DriveClient.h"
#import "../../Runtime/Localization.h"

#import <AuthenticationServices/AuthenticationServices.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>

static NSString *const DriveScope = @"https://www.googleapis.com/auth/drive.file";
static NSString *const DriveAPI = @"https://www.googleapis.com/drive/v3";
static NSString *const TokenURL = @"https://oauth2.googleapis.com/token";
static NSString *const OAuthService = @"com.ytkace.drive-export";

NSError *YTKDriveError(NSString *message) {
    return [NSError errorWithDomain:@"YTKACE.DriveExport" code:1
                           userInfo:@{NSLocalizedDescriptionKey:YTKACELocalized(message)}];
}

static NSString *ClientID(void) {
    return [NSBundle.mainBundle objectForInfoDictionaryKey:@"YTKACEDriveClientID"] ?: @"";
}

static NSString *Base64URL(NSData *data) {
    NSString *encoded = [data base64EncodedStringWithOptions:0];
    encoded = [encoded stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    encoded = [encoded stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [encoded stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

static NSString *RandomVerifier(void) {
    uint8_t bytes[32];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != errSecSuccess) return nil;
    return Base64URL([NSData dataWithBytes:bytes length:sizeof(bytes)]);
}

static NSURLComponents *URLWithQuery(NSString *base, NSDictionary<NSString *, NSString *> *fields) {
    NSURLComponents *components = [NSURLComponents componentsWithString:base];
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:fields.count];
    [fields enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, __unused BOOL *stop) {
        [items addObject:[NSURLQueryItem queryItemWithName:key value:value]];
    }];
    components.queryItems = items;
    return components;
}

static NSData *FormData(NSDictionary<NSString *, NSString *> *fields) {
    NSCharacterSet *unreserved = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    NSMutableArray<NSString *> *pairs = [NSMutableArray arrayWithCapacity:fields.count];
    [fields enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, __unused BOOL *stop) {
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", key,
            [value stringByAddingPercentEncodingWithAllowedCharacters:unreserved]]];
    }];
    return [[pairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
}

static NSMutableDictionary *KeychainQuery(void) {
    return [@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
              (__bridge id)kSecAttrService:OAuthService,
              (__bridge id)kSecAttrAccount:ClientID()} mutableCopy];
}

static NSString *SavedRefreshToken(void) {
    NSMutableDictionary *query = KeychainQuery();
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess) return nil;
    NSData *value = CFBridgingRelease(result);
    return [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding];
}

static void SaveRefreshToken(NSString *token) {
    NSData *data = [token dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary *query = KeychainQuery();
    NSDictionary *attributes = @{(__bridge id)kSecValueData:data};
    if (SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributes) == errSecItemNotFound) {
        [query addEntriesFromDictionary:attributes];
        query[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
        SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    }
}

@interface YTKDriveClient () <ASWebAuthenticationPresentationContextProviding, NSURLSessionTaskDelegate>
@property(atomic, readwrite, getter=isCancelled) BOOL cancelled;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) ASWebAuthenticationSession *browser;
@property(nonatomic, weak) UIWindow *anchor;
@property(nonatomic, copy) NSString *accessToken;
@property(nonatomic, copy) NSString *refreshToken;
@end

@implementation YTKDriveClient

+ (NSString *)configurationProblem {
    if (ClientID().length == 0) return YTKACELocalized(@"Drive export is not configured in this build.");
    NSString *expected = [NSBundle.mainBundle objectForInfoDictionaryKey:@"YTKACEDriveBundleID"];
    NSURL *plist = [NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"Info.plist"];
    // YTKACE rewrites NSBundle's reported identifier for YouTube compatibility.
    NSString *installed = [NSDictionary dictionaryWithContentsOfURL:plist][@"CFBundleIdentifier"];
    if (![expected isEqualToString:installed]) {
        return [NSString stringWithFormat:YTKACELocalized(@"Install with the Drive bundle ID %@."), expected ?: @"–"];
    }
    return nil;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.timeoutIntervalForRequest = 20;
        config.timeoutIntervalForResource = 40;
        _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    }
    return self;
}

- (UIWindow *)presentationAnchorForWebAuthenticationSession:(__unused ASWebAuthenticationSession *)session {
    return self.anchor;
}

- (void)URLSession:(__unused NSURLSession *)session task:(__unused NSURLSessionTask *)task
    willPerformHTTPRedirection:(__unused NSHTTPURLResponse *)response
    newRequest:(__unused NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))handler {
    handler(nil);
}

- (NSData *)perform:(NSURLRequest *)request status:(NSInteger *)status error:(NSError **)error {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSData *body;
    __block NSError *failure;
    __block NSInteger code;
    @synchronized (self) {
        if (self.cancelled) {
            if (error) *error = YTKDriveError(@"Drive export cancelled.");
            return nil;
        }
        NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *problem) {
                body = data;
                failure = problem;
                code = [(NSHTTPURLResponse *)response statusCode];
                dispatch_semaphore_signal(done);
            }];
        [task resume];
    }
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (status) *status = code;
    if (error && failure) *error = YTKDriveError(@"Google Drive could not be reached.");
    return failure ? nil : (body ?: NSData.data);
}

- (BOOL)exchange:(NSDictionary *)fields error:(NSError **)error {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:TokenURL]];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = FormData(fields);
    NSInteger status = 0;
    NSData *data = [self perform:request status:&status error:error];
    if (!data) return NO;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary *reply = [object isKindOfClass:NSDictionary.class] ? object : @{};
    if (status != 200 || ![reply[@"access_token"] isKindOfClass:NSString.class] ||
        [reply[@"access_token"] length] == 0) {
        if ([reply[@"error"] isEqual:@"invalid_grant"] && fields[@"refresh_token"]) {
            SecItemDelete((__bridge CFDictionaryRef)KeychainQuery());
            self.refreshToken = nil;
        }
        if (error) *error = YTKDriveError(@"Google could not authorize Drive. Check the OAuth client and try again.");
        return NO;
    }
    NSString *scopes = [reply[@"scope"] isKindOfClass:NSString.class] ? reply[@"scope"] : nil;
    if (scopes && ![[scopes componentsSeparatedByString:@" "] containsObject:DriveScope]) {
        if (error) *error = YTKDriveError(@"Allow the requested Drive permission to export.");
        return NO;
    }
    self.accessToken = reply[@"access_token"];
    if ([reply[@"refresh_token"] isKindOfClass:NSString.class] && [reply[@"refresh_token"] length]) {
        self.refreshToken = reply[@"refresh_token"];
        SaveRefreshToken(self.refreshToken);
    }
    return YES;
}

- (BOOL)refresh:(NSError **)error {
    if (!self.refreshToken.length) return NO;
    return [self exchange:@{@"client_id":ClientID(), @"grant_type":@"refresh_token",
                            @"refresh_token":self.refreshToken} error:error];
}

- (void)authorizeFrom:(UIViewController *)presenter complete:(void (^)(NSError *))complete {
    NSString *problem = YTKDriveClient.configurationProblem;
    if (problem) {
        complete(YTKDriveError(problem));
        return;
    }
    self.anchor = presenter.view.window;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        self.refreshToken = SavedRefreshToken();
        NSError *error = nil;
        BOOL ready = [self refresh:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ready || self.refreshToken.length || self.cancelled) {
                complete(ready ? nil : (error ?: YTKDriveError(@"Drive export cancelled.")));
            } else {
                [self beginSignIn:complete];
            }
        });
    });
}

- (void)beginSignIn:(void (^)(NSError *))complete {
    NSString *verifier = RandomVerifier();
    NSString *state = RandomVerifier();
    if (verifier == nil || state == nil || self.anchor == nil) {
        complete(YTKDriveError(@"Could not start Google sign-in."));
        return;
    }
    NSData *input = [verifier dataUsingEncoding:NSASCIIStringEncoding];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(input.bytes, (CC_LONG)input.length, hash);
    NSString *scheme = [[[ClientID() componentsSeparatedByString:@"."] reverseObjectEnumerator].allObjects
        componentsJoinedByString:@"."];
    NSString *redirect = [scheme stringByAppendingString:@":/oauthredirect"];
    NSURL *url = URLWithQuery(@"https://accounts.google.com/o/oauth2/v2/auth", @{
        @"client_id":ClientID(), @"redirect_uri":redirect, @"response_type":@"code",
        @"code_challenge_method":@"S256", @"state":state, @"scope":DriveScope,
        @"code_challenge":Base64URL([NSData dataWithBytes:hash length:sizeof(hash)]),
        @"access_type":@"offline", @"prompt":@"consent",
    }).URL;

    self.browser = [[ASWebAuthenticationSession alloc] initWithURL:url callbackURLScheme:scheme
        completionHandler:^(NSURL *callback, NSError *browserError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.browser = nil;
                NSURLComponents *parts = callback ? [NSURLComponents componentsWithURL:callback
                    resolvingAgainstBaseURL:NO] : nil;
                NSMutableDictionary *values = [NSMutableDictionary dictionary];
                for (NSURLQueryItem *item in parts.queryItems) values[item.name] = item.value;
                if (browserError || self.cancelled || ![parts.scheme isEqualToString:scheme] ||
                    ![parts.path isEqualToString:@"/oauthredirect"] || parts.host.length ||
                    ![values[@"state"] isEqual:state] || [values[@"code"] length] == 0) {
                    complete(YTKDriveError(@"Google sign-in did not complete."));
                    return;
                }
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    NSError *error = nil;
                    [self exchange:@{@"code":values[@"code"], @"client_id":ClientID(),
                        @"code_verifier":verifier, @"redirect_uri":redirect,
                        @"grant_type":@"authorization_code"} error:&error];
                    dispatch_async(dispatch_get_main_queue(), ^{ complete(error); });
                });
            });
        }];
    self.browser.presentationContextProvider = self;
    if (![self.browser start]) {
        self.browser = nil;
        complete(YTKDriveError(@"Could not start Google sign-in."));
    }
}

- (NSData *)driveRequest:(NSMutableURLRequest *)request allowConflict:(BOOL)conflict error:(NSError **)error {
    BOOL refreshed = NO;
    for (NSUInteger attempt = 0; attempt < 4 && !self.cancelled; attempt++) {
        [request setValue:[@"Bearer " stringByAppendingString:self.accessToken] forHTTPHeaderField:@"Authorization"];
        NSInteger status = 0;
        NSError *failure = nil;
        NSData *data = [self perform:request status:&status error:&failure];
        if ((status >= 200 && status < 300) || (conflict && status == 409)) return data;
        if (!refreshed && status == 401 && [self refresh:&failure]) {
            refreshed = YES;
            continue;
        }
        BOOL retry = status == 0 || status == 429 || (status >= 500 && status <= 599);
        if (retry && attempt < 3 && !self.cancelled) {
            [NSThread sleepForTimeInterval:(1 << attempt)];
            continue;
        }
        if (error) *error = failure ?: [NSError errorWithDomain:@"YTKACE.DriveHTTP" code:status
            userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:
                YTKACELocalized(@"Google Drive returned HTTP %ld."), (long)status]}];
        return nil;
    }
    if (error) *error = YTKDriveError(@"Drive export cancelled.");
    return nil;
}

- (NSArray<NSString *> *)fileIDs:(NSUInteger)count error:(NSError **)error {
    NSMutableArray *ids = [NSMutableArray arrayWithCapacity:count];
    while (ids.count < count) {
        NSUInteger batch = MIN((NSUInteger)1000, count - ids.count);
        NSURL *url = URLWithQuery([DriveAPI stringByAppendingString:@"/files/generateIds"],
            @{@"count":[@(batch) stringValue], @"space":@"drive"}).URL;
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        NSData *body = [self driveRequest:request allowConflict:NO error:error];
        if (!body) return nil;
        id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
        NSArray *next = [json isKindOfClass:NSDictionary.class] ? json[@"ids"] : nil;
        if (![next isKindOfClass:NSArray.class] || next.count != batch) {
            if (error) *error = YTKDriveError(@"Drive did not allocate file IDs.");
            return nil;
        }
        NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"] invertedSet];
        for (id value in next) {
            if (![value isKindOfClass:NSString.class] || ![value length] ||
                [value rangeOfCharacterFromSet:invalid].location != NSNotFound) {
                if (error) *error = YTKDriveError(@"Drive did not allocate file IDs.");
                return nil;
            }
        }
        [ids addObjectsFromArray:next];
    }
    return ids;
}

- (BOOL)createFolder:(NSString *)name fileID:(NSString *)fileID parent:(NSString *)parent error:(NSError **)error {
    NSMutableDictionary *metadata = [@{@"id":fileID, @"name":name,
        @"mimeType":@"application/vnd.google-apps.folder"} mutableCopy];
    if (parent) metadata[@"parents"] = @[parent];
    NSData *body = [NSJSONSerialization dataWithJSONObject:metadata options:0 error:error];
    if (!body) return NO;
    NSURL *url = [NSURL URLWithString:[DriveAPI stringByAppendingString:@"/files?fields=id"]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    [request setValue:@"application/json; charset=UTF-8" forHTTPHeaderField:@"Content-Type"];
    return [self driveRequest:request allowConflict:YES error:error] != nil;
}

- (BOOL)upload:(NSData *)data name:(NSString *)name mime:(NSString *)mime
        fileID:(NSString *)fileID folder:(NSString *)folder error:(NSError **)error {
    NSDictionary *metadata = @{@"id":fileID, @"name":name, @"mimeType":mime, @"parents":@[folder]};
    NSData *json = [NSJSONSerialization dataWithJSONObject:metadata options:0 error:error];
    if (!json) return NO;
    NSString *boundary = NSUUID.UUID.UUIDString;
    NSString *header = [NSString stringWithFormat:@"--%@\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n", boundary];
    NSMutableData *body = [[header dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [body appendData:json];
    [body appendData:[[NSString stringWithFormat:@"\r\n--%@\r\nContent-Type: %@\r\n\r\n", boundary, mime]
        dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:data];
    [body appendData:[[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:
        @"https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id"]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    [request setValue:[NSString stringWithFormat:@"multipart/related; boundary=%@", boundary]
        forHTTPHeaderField:@"Content-Type"];
    return [self driveRequest:request allowConflict:YES error:error] != nil;
}

- (void)cancel {
    @synchronized (self) {
        self.cancelled = YES;
        [self.session invalidateAndCancel];
    }
    [self.browser cancel];
}

@end
