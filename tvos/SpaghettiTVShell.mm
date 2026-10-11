#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#include <SDL.h>
#include <SDL_syswm.h>
#include <zip.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <sys/socket.h>
#include <unistd.h>
#include <atomic>
#include <mutex>
#include <algorithm>
#include <vector>
#include <TargetConditionals.h>
#include <string>
#include "SpaghettiPadTouchControls.h"
#include "libultraship/bridge/controllerbridge.h"
#include <backends/imgui_impl_sdl2.h>

static NSString *dataPath, *token, *transferURL;
static UIWindow *transferWindow;
static UIWindow *gameWindow;
static UILabel *statusLabel;
static UIButton *continueButton;
static std::atomic<int> listener(-1);
static std::atomic<bool> ready(false), playing(false);
static NSMutableDictionary *savedFiles;
static std::mutex serverMutex;
static int activeClient = -1;
static std::atomic<unsigned long> serverGeneration(0);
static bool resumeTransfer = false;
static const NSUInteger maxArchive = 256 * 1024 * 1024;

static bool SaveName(NSString *name) {
    return [name isEqualToString:@"default.sav"] ||
        ([name rangeOfString:@"^controllerPak_(header|file_[0-9]+)\\.sav$" options:NSRegularExpressionSearch].location != NSNotFound) ||
        [name isEqualToString:@"spaghettify.cfg.json"];
}

extern "C" void SpaghettiTV_PersistSave() {
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"SpaghettiTV.RestorePending"]) return;
    @synchronized(NSUserDefaults.standardUserDefaults) {
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dataPath error:nil]) {
            if (!SaveName(name)) continue;
            NSData *bytes = [NSData dataWithContentsOfFile:[dataPath stringByAppendingPathComponent:name]];
            if (bytes && bytes.length <= 128 * 1024) savedFiles[name] = bytes;
        }
        [NSUserDefaults.standardUserDefaults setObject:savedFiles forKey:@"SpaghettiTV.Saves.v1"];
    }
}

static void Reply(int client, int code, const char *type, NSData *body) {
    NSString *header = [NSString stringWithFormat:@"HTTP/1.1 %d %@\r\nContent-Type: %s\r\nContent-Length: %lu\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n", code, code == 200 ? @"OK" : @"Rejected", type, (unsigned long)body.length];
    NSData *head = [header dataUsingEncoding:NSUTF8StringEncoding];
    for (NSData *part in @[head, body]) {
        const char *p = (const char *)part.bytes;
        size_t remaining = part.length;
        while (remaining) {
            ssize_t sent = send(client, p, remaining, 0);
            if (sent <= 0) return;
            p += sent; remaining -= sent;
        }
    }
}
static void TextReply(int client, int code, NSString *text) {
    Reply(client, code, "text/plain; charset=utf-8", [text dataUsingEncoding:NSUTF8StringEncoding]);
}

static bool ValidArchive(NSString *path) {
    int error = 0;
    zip_t *archive = zip_open(path.fileSystemRepresentation, ZIP_RDONLY | ZIP_CHECKCONS, &error);
    if (!archive) return false;
    bool hasMario = false, hasAudio = false;
    for (zip_uint64_t i = 0; i < (zip_uint64_t)zip_get_num_entries(archive, 0); ++i) {
        const char *name = zip_get_name(archive, i, 0);
        if (!name) continue;
        std::string entry(name);
        hasMario |= entry.find("mario") != std::string::npos;
        hasAudio |= entry.find("sound/") != std::string::npos;
    }
    bool valid = hasMario && hasAudio && zip_get_num_entries(archive, 0) > 1000;
    zip_close(archive);
    return valid;
}

static void HandleClient(int client, NSString *sessionToken, unsigned long generation) {
    timeval timeout = {20, 0};
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    int one = 1;
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    std::string input;
    char buffer[65536];
    size_t split = std::string::npos;
    while ((split = input.find("\r\n\r\n")) == std::string::npos) {
        ssize_t count = recv(client, buffer, sizeof(buffer), 0);
        if (count <= 0) return;
        input.append(buffer, count);
        if (input.size() > 73728) { TextReply(client, 413, @"Headers too large"); return; }
    }
    NSString *headers = [[NSString alloc] initWithBytes:input.data() length:split encoding:NSUTF8StringEncoding];
    NSArray *lines = [headers componentsSeparatedByString:@"\r\n"];
    NSArray *request = [lines.firstObject componentsSeparatedByString:@" "];
    if (request.count != 3) { TextReply(client, 400, @"Bad request"); return; }
    NSString *base = [@"/" stringByAppendingString:sessionToken];
    NSString *path = request[1];
    if (![path isEqualToString:base] && ![path hasPrefix:[base stringByAppendingString:@"/"]]) {
        TextReply(client, 403, @"Use the address displayed on the TV"); return;
    }
    if ([request[0] isEqualToString:@"GET"] && [path isEqualToString:[base stringByAppendingString:@"/saves"]]) {
        SpaghettiTV_PersistSave();
        NSMutableDictionary *backup = [NSMutableDictionary dictionary];
        @synchronized(NSUserDefaults.standardUserDefaults) {
            for (NSString *name in savedFiles) backup[name] = [savedFiles[name] base64EncodedStringWithOptions:0];
        }
        Reply(client, 200, "application/json", [NSJSONSerialization dataWithJSONObject:backup options:0 error:nil]);
        return;
    }
    if ([request[0] isEqualToString:@"GET"] && [path isEqualToString:base]) {
        NSString *page = @"<!doctype html><meta name='viewport' content='width=device-width'><title>SpaghettiPad TV</title><style>body{font:18px system-ui;max-width:650px;margin:60px auto;padding:24px;background:#141822;color:#eee}button,input{font:inherit;margin:12px 0;padding:12px}a{color:#9cf}</style><h1>SpaghettiPad TV</h1><p>Select your locally generated mk64.o2r. The app package contains no game data. Connect up to four gamepads for racing.</p><input id='game' type='file' accept='.o2r'><button onclick='upload(\"game\",\"archive\")'>Import game archive</button><p><a id='backup'>Download save backup</a></p><input id='save' type='file' accept='.json'><button onclick='upload(\"save\",\"restore\")'>Restore save backup</button><p id='status'></p><p>Keep this screen open during transfer. Save restoration takes effect next launch. tvOS may purge game data; keep your archive and save backup on your Mac.</p><script>backup.href=location.pathname+\"/saves\";async function upload(id,route){let f=document.getElementById(id).files[0];if(!f)return;document.getElementById('status').textContent=\"Transferring…\";let r=await fetch(location.pathname+\"/\"+route,{method:\"PUT\",body:f});document.getElementById('status').textContent=await r.text()}</script>";
        Reply(client, 200, "text/html; charset=utf-8", [page dataUsingEncoding:NSUTF8StringEncoding]); return;
    }
    bool archiveRequest = [path isEqualToString:[base stringByAppendingString:@"/archive"]];
    bool restoreRequest = [path isEqualToString:[base stringByAppendingString:@"/restore"]];
    if (![request[0] isEqualToString:@"PUT"] || (!archiveRequest && !restoreRequest)) { TextReply(client, 404, @"Unknown endpoint"); return; }
    if (archiveRequest && playing.load()) { TextReply(client, 409, @"Game already loaded. Relaunch to replace the archive."); return; }
    unsigned long long length = 0;
    for (NSString *line in lines) {
        if ([[line lowercaseString] hasPrefix:@"content-length:"]) length = [[line substringFromIndex:15] longLongValue];
        if ([[line lowercaseString] hasPrefix:@"transfer-encoding:"]) { TextReply(client, 400, @"Content-Length required"); return; }
    }
    if (!length || length > (archiveRequest ? maxArchive : 512 * 1024)) { TextReply(client, 413, @"Invalid upload size"); return; }
    NSString *temporary = [dataPath stringByAppendingPathComponent:[NSString stringWithFormat:@"upload-%@.tmp", sessionToken]];
    FILE *file = fopen(temporary.fileSystemRepresentation, "wb");
    if (!file) { TextReply(client, 500, @"Unable to write upload"); return; }
    size_t received = input.size() - split - 4;
    bool success = received <= length && fwrite(input.data() + split + 4, 1, received, file) == received;
    while (success && received < length) {
        ssize_t count = recv(client, buffer, std::min((unsigned long long)sizeof(buffer), length - received), 0);
        if (count <= 0) { success = false; break; }
        success = fwrite(buffer, 1, count, file) == (size_t)count;
        received += count;
    }
    success &= fclose(file) == 0;
    success &= serverGeneration.load() == generation;
    if (success && archiveRequest) {
        success = ValidArchive(temporary) && !playing.load();
        if (success) {
            NSString *destination = [dataPath stringByAppendingPathComponent:@"mk64.o2r"];
            success = rename(temporary.fileSystemRepresentation, destination.fileSystemRepresentation) == 0;
            ready.store(success);
            if (success) dispatch_async(dispatch_get_main_queue(), ^{
                statusLabel.text = @"Game archive ready. Connect a gamepad, then choose Play.";
                continueButton.enabled = YES;
                [transferWindow.rootViewController setNeedsFocusUpdate];
            });
        }
    } else if (success) {
        NSDictionary *backup = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:temporary] options:0 error:nil];
        NSMutableDictionary *validated = [NSMutableDictionary dictionary];
        success = [backup isKindOfClass:NSDictionary.class] && backup.count <= 32;
        if (success) for (NSString *name in backup) {
            if (![name isKindOfClass:NSString.class] || !SaveName(name) || ![backup[name] isKindOfClass:NSString.class]) { success = false; break; }
            NSData *bytes = [[NSData alloc] initWithBase64EncodedString:backup[name] options:0];
            if (!bytes || bytes.length > 128 * 1024) { success = false; break; }
            validated[name] = bytes;
        }
        if (success) {
            @synchronized(NSUserDefaults.standardUserDefaults) {
                savedFiles = validated;
                [NSUserDefaults.standardUserDefaults setObject:validated forKey:@"SpaghettiTV.Saves.v1"];
                [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"SpaghettiTV.RestorePending"];
            }
            // The running engine may still hold its old save. Restoration is deferred to next launch.
        }
    }
    [NSFileManager.defaultManager removeItemAtPath:temporary error:nil];
    TextReply(client, success ? 200 : 400, success ? (archiveRequest ? @"Archive imported. Choose Play on the TV." : @"Backup restored. Relaunch the app.") : @"Upload rejected; existing data preserved.");
}

static NSString *LocalAddress() {
    ifaddrs *addresses = nullptr;
    NSString *result = @"127.0.0.1";
    if (!getifaddrs(&addresses)) {
        for (ifaddrs *p = addresses; p; p = p->ifa_next) {
            if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET || strncmp(p->ifa_name, "en", 2)) continue;
            char address[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &((sockaddr_in *)p->ifa_addr)->sin_addr, address, sizeof(address));
            result = [NSString stringWithUTF8String:address]; break;
        }
        freeifaddrs(addresses);
    }
    return result;
}
static void StopTransfer() {
    std::lock_guard<std::mutex> lock(serverMutex);
    ++serverGeneration;
    if (activeClient >= 0) shutdown(activeClient, SHUT_RDWR);
    SDL_SetHint(SDL_HINT_APPLE_TV_CONTROLLER_UI_EVENTS, "0");
    if (gameWindow) ControllerUnblockGameInput(0x5456);
    int fd = listener.exchange(-1);
    if (fd >= 0) { shutdown(fd, SHUT_RDWR); close(fd); }
    transferWindow.hidden = YES;
    transferWindow = nil;
    [gameWindow makeKeyAndVisible];
}
static void StartServer() {
    token = NSUUID.UUID.UUIDString;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    sockaddr_in address = {}; address.sin_family = AF_INET; address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(8642);
    if (fd < 0 || bind(fd, (sockaddr *)&address, sizeof(address)) || listen(fd, 2)) {
        if (fd >= 0) close(fd);
        transferURL = @"Transfer server unavailable (port 8642). Relaunch to retry."; return;
    }
    listener.store(fd);
    unsigned long generation = ++serverGeneration;
    NSString *sessionToken = token;
    transferURL = [NSString stringWithFormat:@"http://%@:8642/%@", LocalAddress(), token];
    NSLog(@"[SpaghettiTV] transfer %@", transferURL);
    static dispatch_queue_t serverQueue = dispatch_queue_create("SpaghettiTV.transfer", DISPATCH_QUEUE_SERIAL);
    dispatch_async(serverQueue, ^{
        while (serverGeneration.load() == generation) {
            int client = accept(fd, nullptr, nullptr);
            if (client < 0) break;
            {
                std::lock_guard<std::mutex> lock(serverMutex);
                if (serverGeneration.load() != generation) { close(client); break; }
                activeClient = client;
            }
            @autoreleasepool { HandleClient(client, sessionToken, generation); }
            {
                std::lock_guard<std::mutex> lock(serverMutex);
                activeClient = -1;
                close(client);
            }
        }
    });
}

@interface SpaghettiTVTransferController : UIViewController
@end
@implementation SpaghettiTVTransferController
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = [UIColor colorWithRed:.06 green:.08 blue:.13 alpha:1];
    UIStackView *stack = [[UIStackView alloc] init]; stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 36; stack.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *title = [[UILabel alloc] init]; title.text = @"SpaghettiPad TV"; title.font = [UIFont boldSystemFontOfSize:54]; title.textColor = UIColor.whiteColor;
    UILabel *instructions = [[UILabel alloc] init]; instructions.numberOfLines = 0; instructions.textColor = UIColor.whiteColor;
    instructions.text = [NSString stringWithFormat:@"On your Mac, open:\n%@\n\nImport your local mk64.o2r, or download/restore a save backup.\nGame data can be purged by tvOS; keep a copy on your Mac.\nPair up to four gamepads in Apple TV Settings. A = accelerate, X = brake, left stick = steer, Start = pause.\nPress View / Back in game for controller settings; open Transfer from that menu.", transferURL];
    instructions.font = [UIFont systemFontOfSize:27];
    statusLabel = [[UILabel alloc] init]; statusLabel.textColor = UIColor.whiteColor;
    statusLabel.text = ready.load() ? @"Game archive ready" : @"Waiting for game archive";
    continueButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [continueButton setTitle:playing.load() ? @"Return to game" : @"Play" forState:UIControlStateNormal];
    continueButton.enabled = ready.load();
    [continueButton addTarget:self action:@selector(play) forControlEvents:UIControlEventPrimaryActionTriggered];
    for (UIView *v in @[title, instructions, statusLabel, continueButton]) [stack addArrangedSubview:v];
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:100], [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-100], [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]]];
}
- (void)play { if (ready.load()) { playing.store(true); StopTransfer(); } }
- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments { return continueButton.enabled ? @[continueButton] : @[]; }
@end
static void ShowTransfer() {
    if (transferWindow) return;
    SDL_SetHint(SDL_HINT_APPLE_TV_CONTROLLER_UI_EVENTS, "1");
    if (gameWindow) ControllerBlockGameInput(0x5456);
    StartServer();
    transferWindow = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) if ([scene isKindOfClass:UIWindowScene.class]) { transferWindow.windowScene = (UIWindowScene *)scene; break; }
    transferWindow.windowLevel = UIWindowLevelAlert + 1;
    transferWindow.rootViewController = [[SpaghettiTVTransferController alloc] init];
    [transferWindow makeKeyAndVisible];
}
extern "C" void SpaghettiTV_PrepareGameData() {
    SDL_SetHint(SDL_HINT_TV_REMOTE_AS_JOYSTICK, "0");
    dataPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/SpaghettiPad"];
    [NSFileManager.defaultManager createDirectoryAtPath:dataPath withIntermediateDirectories:YES attributes:nil error:nil];
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"SpaghettiTV.RestorePending"]) {
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dataPath error:nil])
            if (SaveName(name)) [NSFileManager.defaultManager removeItemAtPath:[dataPath stringByAppendingPathComponent:name] error:nil];
    }
    savedFiles = [[NSUserDefaults.standardUserDefaults dictionaryForKey:@"SpaghettiTV.Saves.v1"] mutableCopy] ?: [NSMutableDictionary dictionary];
    for (NSString *name in savedFiles) if (SaveName(name) && [savedFiles[name] isKindOfClass:NSData.class]) [savedFiles[name] writeToFile:[dataPath stringByAppendingPathComponent:name] atomically:YES];
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"SpaghettiTV.RestorePending"];
    ready.store(ValidArchive([dataPath stringByAppendingPathComponent:@"mk64.o2r"]));
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(NSNotification *) {
        SpaghettiTV_PersistSave();
        resumeTransfer = transferWindow != nil;
        StopTransfer();
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *) {
        if (resumeTransfer) { resumeTransfer = false; ShowTransfer(); }
    }];
    ShowTransfer();
    while (!playing.load()) {
#if TARGET_OS_SIMULATOR
        if (ready.load() && [NSProcessInfo.processInfo.environment[@"SPAGHETTIPAD_TV_AUTOPLAY"] boolValue]) { playing.store(true); StopTransfer(); break; }
#endif
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
    }
}
void SpaghettiTV_OpenTransfer() { dispatch_async(dispatch_get_main_queue(), ^{ ShowTransfer(); }); }
void SpaghettiPad_OnWindowCreated(SDL_Window *window) {
    SDL_SysWMinfo info = {}; SDL_VERSION(&info.version);
    if (SDL_GetWindowWMInfo(window, &info)) gameWindow = info.info.uikit.window;
}
int SpaghettiPad_TouchControlsAvailable() { return 0; }
#if TARGET_OS_SIMULATOR
static std::vector<SDL_Joystick *> testControllers;
static void ConfigureSimulatorControllers() {
    int count = std::clamp([NSProcessInfo.processInfo.environment[@"SPAGHETTIPAD_SIMULATE_CONTROLLERS"] intValue], 0, 4);
    for (int i = 0; i < count; ++i) {
        SDL_VirtualJoystickDesc descriptor = {};
        descriptor.version = SDL_VIRTUAL_JOYSTICK_DESC_VERSION;
        descriptor.type = SDL_JOYSTICK_TYPE_GAMECONTROLLER;
        descriptor.naxes = SDL_CONTROLLER_AXIS_MAX;
        descriptor.nbuttons = SDL_CONTROLLER_BUTTON_MAX;
        descriptor.axis_mask = (1u << SDL_CONTROLLER_AXIS_MAX) - 1;
        descriptor.button_mask = (1u << SDL_CONTROLLER_BUTTON_MAX) - 1;
        descriptor.name = "SpaghettiTV Simulator Gamepad";
        int device = SDL_JoystickAttachVirtualEx(&descriptor);
        if (device >= 0) testControllers.push_back(SDL_JoystickOpen(device));
    }
    if (testControllers.empty()) return;
    [NSTimer scheduledTimerWithTimeInterval:.03 repeats:YES block:^(NSTimer *) {
        NSArray *ports = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[dataPath stringByAppendingPathComponent:@"test-input.json"]] ?: [NSData data] options:0 error:nil];
        if (![ports isKindOfClass:NSArray.class]) return;
        for (NSUInteger i = 0; i < testControllers.size(); ++i) {
            NSDictionary *port = i < ports.count && [ports[i] isKindOfClass:NSDictionary.class] ? ports[i] : @{};
            NSArray *buttons = port[@"buttons"], *axes = port[@"axes"];
            for (int button = 0; button < SDL_CONTROLLER_BUTTON_MAX; ++button) SDL_JoystickSetVirtualButton(testControllers[i], button, [buttons isKindOfClass:NSArray.class] && button < buttons.count && [buttons[button] boolValue]);
            for (int axis = 0; axis < SDL_CONTROLLER_AXIS_MAX; ++axis) SDL_JoystickSetVirtualAxis(testControllers[i], axis, [axes isKindOfClass:NSArray.class] && axis < axes.count ? [axes[axis] intValue] : (axis >= SDL_CONTROLLER_AXIS_TRIGGERLEFT ? -32768 : 0));
        }
        SDL_JoystickUpdate();
    }];
}
#endif

void SpaghettiPad_InitializeTouchControls() {
#if TARGET_OS_SIMULATOR
    ConfigureSimulatorControllers();
#endif
    // Allow settings navigation from every paired pad, including after reconnects.
    ImGui_ImplSDL2_SetGamepadMode(ImGui_ImplSDL2_GamepadMode_AutoAll);
    SDL_SetHint(SDL_HINT_APPLE_TV_REMOTE_ALLOW_ROTATION, "0");
    SDL_SetHint(SDL_HINT_APPLE_TV_CONTROLLER_UI_EVENTS, "0");
    [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *) {
        if (![NSUserDefaults.standardUserDefaults boolForKey:@"SpaghettiTV.RestorePending"]) SpaghettiTV_PersistSave();
    }];

}
void SpaghettiPad_SetTouchControlsEnabled(int) {}
void SpaghettiPad_SetLegacyTouchControlsEnabled(int) {}
void SpaghettiPad_BeginTouchLayoutEditing() {}
void SpaghettiPad_SetTouchControlsMenuVisible(int) {}
void SpaghettiPad_SetGameplayActive(int) {}
void SpaghettiPad_SetTiltSteeringEnabled(int) {}
void SpaghettiPad_SetTiltSensitivity(float) {}
void SpaghettiPad_RecenterTiltSteering() {}
float SpaghettiPad_RecommendedMenuScale() { return 1.5f; }
void SpaghettiPad_RecordRawStick(int, int) {}
void SpaghettiPad_RecordControllerButtons(unsigned int held, unsigned int pressed) {
#if TARGET_OS_SIMULATOR
    static unsigned int previous;
    if (held != previous || pressed) SDL_Log("[SpaghettiTV] controller held=%04x pressed=%04x", held, pressed);
    previous = held;
#endif
}
