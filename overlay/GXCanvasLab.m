/* SPDX-License-Identifier: GPL-3.0-only
 * Unofficial experimental add-on for GestaltX v1.1.1.
 * No arbitrary file browser, remote service, device reboot, or restore exploit.
 */
#import "GXCanvasLab.h"
#import "GXCanvasAtomic.h"
#import "../GXCustomizationAccess.h"
#import "../worse_query.h"
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonHMAC.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

static NSString *const GXCLFilename = @"com.apple.iokit.IOMobileGraphicsFamily.plist";
static const NSUInteger GXCLMaxFile = 4 * 1024 * 1024;

static NSURL *GXCLDirectory(void) {
    NSURL *base = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    return [base URLByAppendingPathComponent:@"CanvasLab" isDirectory:YES];
}
NSURL *GXCLReportURL(void) { return [GXCLDirectory() URLByAppendingPathComponent:@"last-report.txt"]; }
NSURL *GXCLBackupURL(void) { return [GXCLDirectory() URLByAppendingPathComponent:@"original-backup.plist"]; }
static NSURL *GXCLStateURL(void) { return [GXCLDirectory() URLByAppendingPathComponent:@"allowed-states.plist"]; }
static BOOL GXCLMakeDirectory(NSError **error) {
    return [NSFileManager.defaultManager createDirectoryAtURL:GXCLDirectory() withIntermediateDirectories:YES
                                                  attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:error];
}
static NSString *GXCLSysctl(const char *name) {
    char text[256] = {0}; size_t size = sizeof(text) - 1;
    return sysctlbyname(name, text, &size, NULL, 0) == 0 ? [NSString stringWithUTF8String:text] : @"unknown";
}
static NSString *GXCLHash(NSData *data) {
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    NSMutableString *out = NSMutableString.new;
    for (NSUInteger i = 0; i < sizeof(hash); i++) [out appendFormat:@"%02x", hash[i]];
    return out;
}
static NSData *GXCLMAC(NSData *payload, NSData *key) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, payload.bytes, payload.length, bytes);
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}
static NSError *GXCLError(NSString *text) {
    return [NSError errorWithDomain:@"CanvasLab" code:1 userInfo:@{NSLocalizedDescriptionKey:text}];
}
static NSData *GXCLKey(BOOL create, NSError **error) {
    NSString *service = [(NSBundle.mainBundle.bundleIdentifier ?: @"GestaltX") stringByAppendingString:@".CanvasLab.backup"];
    NSDictionary *query = @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
                            (__bridge id)kSecAttrService:service,
                            (__bridge id)kSecAttrAccount:@"device-only-hmac-v1"};
    NSMutableDictionary *read = query.mutableCopy;
    read[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)read, &result);
    if (status == errSecSuccess) {
        id value = CFBridgingRelease(result);
        if ([value isKindOfClass:NSData.class] && [value length] == 32) return value;
        if (error) *error = GXCLError(@"Keychain backup key is invalid; nothing was written.");
        return nil;
    }
    if (status != errSecItemNotFound || !create) {
        if (error) *error = GXCLError([NSString stringWithFormat:@"Device-only backup key unavailable (%d).", (int)status]);
        return nil;
    }
    unsigned char random[32];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(random), random) != errSecSuccess) {
        if (error) *error = GXCLError(@"Secure random generation failed."); return nil;
    }
    NSData *key = [NSData dataWithBytes:random length:sizeof(random)];
    NSMutableDictionary *add = query.mutableCopy;
    add[(__bridge id)kSecValueData] = key;
    add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    add[(__bridge id)kSecAttrSynchronizable] = @NO;
    status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    if (status != errSecSuccess) {
        if (error) *error = GXCLError([NSString stringWithFormat:@"Cannot save device-only backup key (%d).", (int)status]);
        return nil;
    }
    return key;
}
static NSDictionary *GXCLLoadSigned(NSURL *url, NSData *key, NSError **error) {
    NSData *disk = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (!disk || disk.length > GXCLMaxFile * 2) return nil;
    id outer = [NSPropertyListSerialization propertyListWithData:disk options:NSPropertyListImmutable format:NULL error:error];
    if (![outer isKindOfClass:NSDictionary.class] || ![outer[@"payload"] isKindOfClass:NSData.class] ||
        ![outer[@"mac"] isKindOfClass:NSData.class] || ![GXCLMAC(outer[@"payload"], key) isEqual:outer[@"mac"]]) {
        if (error) *error = GXCLError(@"Backup/state authentication failed. Nothing was written."); return nil;
    }
    id value = [NSPropertyListSerialization propertyListWithData:outer[@"payload"] options:NSPropertyListImmutable format:NULL error:error];
    if (![value isKindOfClass:NSDictionary.class]) {
        if (error) *error = GXCLError(@"Invalid authenticated record."); return nil;
    }
    return value;
}
static BOOL GXCLSaveSigned(NSURL *url, NSDictionary *value, NSData *key, BOOL firstOnly, NSError **error) {
    NSData *payload = [NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!payload) return NO;
    NSData *disk = [NSPropertyListSerialization dataWithPropertyList:@{@"payload":payload,@"mac":GXCLMAC(payload,key)}
                                                            format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!disk || !GXCLMakeDirectory(error)) return NO;
    if (firstOnly) {
        int fd = open(url.fileSystemRepresentation, O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC, 0600);
        if (fd < 0) { if (error) *error = GXCLError(@"Cannot exclusively create the first backup."); return NO; }
        NSUInteger offset = 0; BOOL ok = YES;
        while (offset < disk.length) {
            ssize_t n = write(fd, (const char *)disk.bytes + offset, disk.length - offset);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { ok = NO; break; }
            offset += (NSUInteger)n;
        }
        if (ok && fsync(fd)) ok = NO;
        close(fd);
        if (!ok) { if (error) *error = GXCLError(@"Backup write/sync failed. Target untouched; do not delete or bypass the failed backup automatically."); return NO; }
    } else if (![disk writeToURL:url options:NSDataWritingAtomic error:error]) return NO;
    /* Foundation's atomic state-file write alone does not establish fsync. */
    int saved = open(url.fileSystemRepresentation, O_RDWR|O_NOFOLLOW|O_CLOEXEC);
    if (saved < 0) { if (error) *error = GXCLError(@"Cannot reopen backup/state for synchronization. Target untouched."); return NO; }
    int syncResult = fsync(saved);
    close(saved);
    if (syncResult) { if (error) *error = GXCLError(@"Backup/state synchronization failed. Target untouched."); return NO; }
    NSDictionary *verified = GXCLLoadSigned(url, key, error);
    if (![verified isEqual:value]) { if (error && !*error) *error = GXCLError(@"Backup/state read-back failed."); return NO; }
    /* Directory fsync is best-effort on iOS; full power-loss durability is not guaranteed. */
    int dir = open(GXCLDirectory().fileSystemRepresentation, O_RDONLY|O_DIRECTORY|O_CLOEXEC);
    if (dir >= 0) { (void)fsync(dir); close(dir); }
    return YES;
}
static NSData *GXCLReadFile(int fd, NSError **error) {
    struct stat s;
    if (fstat(fd,&s) || !S_ISREG(s.st_mode) || s.st_size <= 0 || s.st_size > (off_t)GXCLMaxFile) {
        if (error) *error = GXCLError(@"File is missing, empty, non-regular, or too large."); return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)s.st_size];
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t n = pread(fd,(char *)data.mutableBytes+offset,data.length-offset,(off_t)offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { if (error) *error = GXCLError(@"Short read; nothing was written."); return nil; }
        offset += (NSUInteger)n;
    }
    return data;
}
static BOOL GXCLSupported(NSMutableString *log) {
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
    NSString *model = GXCLSysctl("hw.machine"), *build = GXCLSysctl("kern.osversion");
    [log appendFormat:@"Canvas Lab 0.1 — UNVERIFIED ON DEVICE\nModel: %@\niOS: %ld.%ld.%ld\nBuild: %@\n",model,(long)os.majorVersion,(long)os.minorVersion,(long)os.patchVersion,build];
    if (![model isEqual:@"iPhone14,5"] || os.majorVersion != 27 || os.minorVersion != 2 || os.patchVersion != 0) {
        [log appendString:@"BLOCKED: this experiment is restricted to physical iPhone 13 / iOS 27.2.0.\n"]; return NO;
    }
    return YES;
}
static NSDictionary *GXCLResult(BOOL ok, BOOL inspected, BOOL changed, NSString *message, NSMutableString *log) {
    [log appendFormat:@"\nResult: %@\nSystem file changed by this operation: %@\n", message, changed?@"YES":@"NO"];
    NSError *error = nil;
    if (GXCLMakeDirectory(&error)) [log writeToURL:GXCLReportURL() atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (error) [log appendFormat:@"Report could not be saved: %@\n",error.localizedDescription];
    return @{@"ok":@(ok),@"inspected":@(inspected),@"changed":@(changed),@"message":message,@"report":[log copy]};
}

typedef NSDictionary *(^GXCLAction)(int directory, int file, NSData *bytes, NSDictionary *plist, NSMutableString *log);
static NSDictionary *GXCLWithTarget(GXCLAction action, NSMutableString *log) {
    for (NSString *parent in @[@"/var/mobile/Library/Preferences",@"/private/var/mobile/Library/Preferences"]) {
        NSString *file = [parent stringByAppendingPathComponent:GXCLFilename];
        int64_t dh = [GXCustomizationAccess acquirePath:parent];
        int64_t fh = [GXCustomizationAccess acquirePath:file];
        [log appendFormat:@"\nParent: %@\nDirectory extension: %lld\nFile extension: %lld\n",parent,(long long)dh,(long long)fh];
        int dir = open(parent.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        int fd = dir >= 0 ? openat(dir,GXCLFilename.UTF8String,O_RDWR|O_NOFOLLOW|O_CLOEXEC) : -1;
        int openError = errno;
        NSDictionary *out = nil;
        if (dir >= 0 && fd >= 0) {
            NSError *error = nil;
            NSData *data = GXCLReadFile(fd,&error);
            id plist = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:&error] : nil;
            if (data && [plist isKindOfClass:NSDictionary.class]) {
                struct stat s;
                if (!fstat(fd,&s) && s.st_uid == geteuid() && s.st_nlink == 1 && !(s.st_mode & (0022 | 07000))) {
                    [log appendFormat:@"O_RDWR without truncation: OK\nBytes: %lu\nSHA256: %@\ncanvas_width: %@\ncanvas_height: %@\n",(unsigned long)data.length,GXCLHash(data),plist[@"canvas_width"]?:@"absent",plist[@"canvas_height"]?:@"absent"];
                    out = action(dir,fd,data,plist,log);
                } else [log appendString:@"Unsafe owner, links, or mode; refused.\n"];
            } else [log appendFormat:@"Read/plist validation failed: %@\n",error.localizedDescription?:@"dictionary required"];
        } else [log appendFormat:@"Open rejected: errno=%d (%s). No target file created.\n",openError,strerror(openError)];
        if (fd >= 0) close(fd);
        if (dir >= 0) close(dir);
        if (fh >= 0) worse_query_release(fh);
        if (dh >= 0) worse_query_release(dh);
        if (out) return out;
    }
    return GXCLResult(NO,NO,NO,@"ACCESS_DENIED_OR_UNSUPPORTED_FILE: 접근이 거부되었거나 기존 plist를 안전하게 열 수 없습니다. 설정은 변경하지 않았습니다.",log);
}
static NSDictionary *GXCLBackup(NSData *current, BOOL create, NSData *key, NSMutableString *log, NSError **error) {
    BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:GXCLBackupURL().path];
    if (!exists && !create) { if(error)*error=GXCLError(@"실험 전 백업이 없습니다."); return nil; }
    if (!exists) {
        NSDictionary *value = @{@"schema":@1,@"model":GXCLSysctl("hw.machine"),@"build":GXCLSysctl("kern.osversion"),
                                @"path":@"/var/mobile/Library/Preferences/com.apple.iokit.IOMobileGraphicsFamily.plist",
                                @"created":[NSDate date],@"original":current,@"sha256":GXCLHash(current)};
        if (!GXCLSaveSigned(GXCLBackupURL(),value,key,YES,error)) return nil;
        [log appendString:@"Initial backup created, authenticated, synced, and read back.\n"];
    }
    NSDictionary *backup = GXCLLoadSigned(GXCLBackupURL(),key,error);
    NSData *original = backup[@"original"];
    if (!backup || ![backup[@"schema"] isEqual:@1] || ![original isKindOfClass:NSData.class] ||
        ![backup[@"model"] isEqual:GXCLSysctl("hw.machine")] || ![backup[@"build"] isEqual:GXCLSysctl("kern.osversion")] ||
        ![backup[@"sha256"] isEqual:GXCLHash(original)] ||
        ![backup[@"path"] isEqual:@"/var/mobile/Library/Preferences/com.apple.iokit.IOMobileGraphicsFamily.plist"]) {
        if(error)*error=GXCLError(@"백업 인증 또는 기기/빌드/경로 검증에 실패했습니다."); return nil;
    }
    return backup;
}
static NSMutableSet<NSString *> *GXCLAllowed(NSDictionary *backup, NSData *key, NSError **error) {
    NSMutableSet *allowed=[NSMutableSet setWithObject:backup[@"sha256"]];
    if ([NSFileManager.defaultManager fileExistsAtPath:GXCLStateURL().path]) {
        NSDictionary *state=GXCLLoadSigned(GXCLStateURL(),key,error);
        if (!state || ![state[@"backupSHA256"] isEqual:backup[@"sha256"]] || ![state[@"hashes"] isKindOfClass:NSArray.class]) {
            if(error)*error=GXCLError(@"실험 상태 기록을 검증할 수 없습니다."); return nil;
        }
        for (id hash in state[@"hashes"]) {
            if (![hash isKindOfClass:NSString.class] || [hash length]!=64) { if(error)*error=GXCLError(@"잘못된 상태 해시입니다."); return nil; }
            [allowed addObject:hash];
        }
    }
    return allowed;
}
NSDictionary *GXCLInspect(void) {
    @synchronized([GXCustomizationAccess class]) {
        NSMutableString *log=NSMutableString.new;
        if(!GXCLSupported(log))return GXCLResult(NO,NO,NO,@"지원 대상이 아닙니다. 변경하지 않았습니다.",log);
        return GXCLWithTarget(^NSDictionary *(int dir,int fd,NSData *bytes,NSDictionary *plist,NSMutableString *lines){
            [lines appendString:@"Inspection only: no display-setting bytes were changed.\nAtomic replacement permission is NOT proven until Apply prepares a temporary file.\n"];
            return GXCLResult(YES,YES,NO,@"검사 통과: 기존 파일 읽기·쓰기 열기 성공. 실제 적용 권한과 화면 효과는 아직 미검증입니다.",lines);
        },log);
    }
}
static NSDictionary *GXCLChange(NSInteger width,NSInteger height,BOOL restore) {
    @synchronized([GXCustomizationAccess class]) {
        NSMutableString *log=NSMutableString.new;
        if(!GXCLSupported(log))return GXCLResult(NO,NO,NO,@"지원 대상이 아닙니다. 변경하지 않았습니다.",log);
        if(!restore&&!((width==1179&&height==2556)||(width==1206&&height==2622)))
            return GXCLResult(NO,NO,NO,@"허용된 두 캔버스 프리셋만 적용할 수 있습니다.",log);
        return GXCLWithTarget(^NSDictionary *(int dir,int fd,NSData *bytes,NSDictionary *plist,NSMutableString *lines){
            NSError *error=nil;
            NSData *key=GXCLKey(!restore,&error);
            NSDictionary *backup=key?GXCLBackup(bytes,!restore,key,lines,&error):nil;
            NSMutableSet *allowed=backup?GXCLAllowed(backup,key,&error):nil;
            if(!allowed||![allowed containsObject:GXCLHash(bytes)])
                return GXCLResult(NO,YES,NO,error.localizedDescription?:@"현재 파일이 백업/이 실험의 기록과 다릅니다. 다른 변경을 덮어쓰지 않기 위해 중단했습니다.",lines);
            NSData *next=nil;
            if(restore)next=backup[@"original"];
            else {
                NSMutableDictionary *edited=[plist mutableCopy];
                edited[@"canvas_width"]=@(width); edited[@"canvas_height"]=@(height);
                next=[NSPropertyListSerialization dataWithPropertyList:edited format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
                NSDictionary *check=next?[NSPropertyListSerialization propertyListWithData:next options:NSPropertyListImmutable format:NULL error:&error]:nil;
                if(![check isEqual:edited])next=nil;
            }
            if(!next||!next.length||next.length>GXCLMaxFile)
                return GXCLResult(NO,YES,NO,error.localizedDescription?:@"변경 결과 plist 검증 실패.",lines);
            if([bytes isEqual:next])return GXCLResult(YES,YES,NO,@"이미 요청한 파일 내용입니다. 쓰기를 생략했습니다.",lines);
            [allowed addObject:GXCLHash(next)];
            NSDictionary *state=@{@"backupSHA256":backup[@"sha256"],@"hashes":[allowed.allObjects sortedArrayUsingSelector:@selector(compare:)]};
            if(!GXCLSaveSigned(GXCLStateURL(),state,key,NO,&error))
                return GXCLResult(NO,YES,NO,error.localizedDescription?:@"복원 상태 기록을 저장하지 못해 중단했습니다.",lines);
            char detail[512]={0};
            int result=gxcl_atomic_replace(dir,fd,bytes.bytes,bytes.length,next.bytes,next.length,detail,sizeof(detail));
            [lines appendFormat:@"Commit: %s\n",detail];
            if(result<0)return GXCLResult(NO,YES,NO,@"적용 전 중단: 원본 설정 파일은 교체하지 않았습니다. 로그를 확인하세요.",lines);
            if(result>0)return GXCLResult(NO,YES,YES,@"주의: 파일 교체 후 재검증 실패. 재부팅하지 말고 원본 복원 또는 복구 지원이 필요합니다.",lines);
            return GXCLResult(YES,YES,YES,restore?@"실험 전 원본 바이트로 복원하고 재확인했습니다. 필요하면 직접 재시작하세요.":@"두 캔버스 키를 변경하고 파일 재확인을 마쳤습니다. 화면 반영 여부는 별도입니다. 백업을 내보낸 뒤 직접 재시작하세요.",lines);
        },log);
    }
}
NSDictionary *GXCLApply(NSInteger width,NSInteger height){return GXCLChange(width,height,NO);}
NSDictionary *GXCLRestore(void){return GXCLChange(0,0,YES);}
