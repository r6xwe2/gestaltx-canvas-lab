/* SPDX-License-Identifier: GPL-3.0-only */
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/* These functions serialize their own operations; none runs on launch. */
FOUNDATION_EXPORT NSDictionary<NSString *, id> *GXCLInspect(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *GXCLApply(NSInteger width, NSInteger height);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *GXCLRestore(void);
FOUNDATION_EXPORT NSURL *GXCLReportURL(void);
FOUNDATION_EXPORT NSURL *GXCLBackupURL(void);
NS_ASSUME_NONNULL_END
