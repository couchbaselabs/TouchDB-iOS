//
//  TDReplicator+Backgrounding.m
//  CouchbaseLite
//
//  Created by Jens Alfke on 8/15/13.
//
//

#if TARGET_OS_IPHONE

#import "TDReplicator.h"
#import "TDInternal.h"
#import "MYBlockUtils.h"

#import <UIKit/UIKit.h>


@implementation TDReplicator (Backgrounding)


// Called when the replicator starts
- (void) setupBackgrounding {
    _bgTask = UIBackgroundTaskInvalid;
    [[NSNotificationCenter defaultCenter] addObserver: self selector: @selector(appBackgrounding:)
                                                 name: UIApplicationDidEnterBackgroundNotification
                                               object: nil];
    [[NSNotificationCenter defaultCenter] addObserver: self selector: @selector(appForegrounding:)
                                                 name: UIApplicationWillEnterForegroundNotification
                                               object: nil];
}


- (void) endBGTask {
    if (_bgTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask: _bgTask];
        _bgTask = UIBackgroundTaskInvalid;
    }
}


// Called when the replicator stops
- (void) endBackgrounding {
    [self endBGTask];
    [[NSNotificationCenter defaultCenter] removeObserver: self
                                                    name: UIApplicationDidEnterBackgroundNotification
                                                  object: nil];
    [[NSNotificationCenter defaultCenter] removeObserver: self
                                                    name: UIApplicationWillEnterForegroundNotification
                                                  object: nil];
}


// Called when the replicator goes idle
- (void) okToEndBackgrounding {
    if (_bgTask != UIBackgroundTaskInvalid) {
        LogTo(Sync, @"%@: Now idle; stopping background task (%d)", self, _bgTask);
        [self stop];
    }
}


- (void) appBackgrounding: (NSNotification*)n {
    // Danger: This is called on the main thread! It switches to the replicator's thread to do its
    // work, but it has to block until that work is done, because UIApplication requires
    // background tasks to be registered before the notification handler returns; otherwise the app
    // simply suspends itself.
    NSLog(@"APP BACKGROUNDING");
    MYOnThreadSynchronously(_thread, ^{
        if (self.active) {
            _bgTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler: ^{
                // Called if process runs out of background time before replication finishes:
                MYOnThreadSynchronously(_thread, ^{
                    LogTo(Sync, @"%@: Background task (%d) ran out of time!", self, _bgTask);
                    [self stop];
                });
            }];
            LogTo(Sync, @"%@: App going into background (bgTask=%d)", self, _bgTask);
            if (_bgTask == UIBackgroundTaskInvalid) {
                // Backgrounding isn't possible for whatever reason, so just stop now:
                [self stop];
            }
        } else {
            LogTo(Sync, @"%@: App going into background", self);//TEMP
            [self stop];
        }
    });
}


- (void) appForegrounding: (NSNotification*)n {
    // Danger: This is called on the main thread!
    NSLog(@"APP FOREGROUNDING");
    MYOnThread(_thread, ^{
        if (_bgTask != UIBackgroundTaskInvalid) {
            LogTo(Sync, @"%@: App returning to foreground (bgTask=%d)", self, _bgTask);
            [self endBGTask];
        }
    });
}


@end

#endif // TARGET_OS_IPHONE