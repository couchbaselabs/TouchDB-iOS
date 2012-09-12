//
//  TDServer.m
//  TouchDB
//
//  Created by Jens Alfke on 11/30/11.
//  Copyright (c) 2011 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "TDServer.h"
#import <TouchDB/TDDatabase.h>
#import "TDReplicatorManager.h"
#import "TDMisc.h"
#import "TDDatabaseManager.h"
#import "TDInternal.h"
#import "TDURLProtocol.h"

#import "MYBlockUtils.h"
#import "Logging.h"
#import "Test.h"


@implementation TDServer


#if DEBUG
+ (TDServer*) createEmptyAtPath: (NSString*)path {
    [[NSFileManager defaultManager] removeItemAtPath: path error: NULL];
    NSError* error;
    TDServer* server = [[self alloc] initWithDirectory: path error: &error];
    Assert(server, @"Failed to create server at %@: %@", path, error);
    AssertEqual(server.directory, path);
    return [server autorelease];
}

+ (TDServer*) createEmptyAtTemporaryPath: (NSString*)name {
    return [self createEmptyAtPath: [NSTemporaryDirectory() stringByAppendingPathComponent: name]];
}
#endif


- (id) initWithDirectory: (NSString*)dirPath error: (NSError**)outError {
    if (outError) *outError = nil;
    self = [super init];
    if (self) {
        _manager = [[TDDatabaseManager alloc] initWithDirectory: dirPath error: outError];
        if (!_manager) {
            [self release];
            return nil;
        }
        
        _serverThread = [[NSThread alloc] initWithTarget: self
                                                selector: @selector(runServerThread)
                                                  object: nil];
        LogTo(TDServer, @"Starting server thread %@ ...", _serverThread);
        [_serverThread start];
    }
    return self;
}


- (void)dealloc
{
    LogTo(TDServer, @"DEALLOC");
    if (_serverThread) Warn(@"%@ dealloced with _serverThread still set: %@", self, _serverThread);
    [_manager release];
    [super dealloc];
}


- (void) close {
    if (_serverThread) {
        [self queue: ^{
            LogTo(TDServer, @"Stopping server thread...");
            [TDURLProtocol unregisterServer: self];
            _stopRunLoop = YES;
        }];
        [_serverThread release];
        _serverThread = nil;
    }
}


- (NSString*) directory {
    return _manager.directory;
}


- (void) runServerThread {
    @autoreleasepool {
        [[self retain] autorelease]; // ensure self stays alive till this method returns
        
        @autoreleasepool {
            LogTo(TDServer, @"Server thread starting...");

            [[NSThread currentThread] setName:@"TouchDB"];
            
#ifndef GNUSTEP
            // Add a no-op source so the runloop won't stop on its own:
            CFRunLoopSourceContext context = {};  // all zeros
            CFRunLoopSourceRef source = CFRunLoopSourceCreate(NULL, 0, &context);
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
            CFRelease(source);
#endif
            
            // Initialize the replicator:
            [_manager replicatorManager];
        }
        
        // Now run:
        while (!_stopRunLoop && [[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
                                                         beforeDate: [NSDate distantFuture]])
            ;
        
        LogTo(TDServer, @"Server thread exiting");

        // Clean up; this has to be done on the server thread, not in the -close method.
        [_manager close];
    }
}


- (void) queue: (void(^)())block {
    Assert(_serverThread, @"-queue: called after -close");
    MYOnThread(_serverThread, block);
}


- (void) tellDatabaseNamed: (NSString*)dbName to: (void (^)(TDDatabase*))block {
    [self queue: ^{ block([_manager databaseNamed: dbName]); }];
}


- (void) tellDatabaseManager: (void (^)(TDDatabaseManager*))block {
    [self queue: ^{ block(_manager); }];
}


@end



NSURL* TDStartServer(NSString* serverDirectory, NSError** outError) {
    CAssert(![TDURLProtocol server], @"A TDServer is already running");
    TDServer* tdServer = [[[TDServer alloc] initWithDirectory: serverDirectory
                                                        error: outError] autorelease];
    if (!tdServer)
        return nil;
    return [TDURLProtocol registerServer: tdServer forHostname: nil];
}




TestCase(TDServer) {
    RequireTestCase(TDDatabaseManager);
}
