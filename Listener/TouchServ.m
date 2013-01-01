//
//  TouchServ.m
//  TouchServ
//
//  Created by Jens Alfke on 1/16/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import <Foundation/Foundation.h>
#import "TouchDB.h"
#import "TD_Server.h"
#import "TDURLProtocol.h"
#import "TDRouter.h"
#import "TDListener.h"
#import "TDPusher.h"
#import "TD_DatabaseManager.h"
#import "TD_Database+Replication.h"
#import "TDMisc.h"

#if DEBUG
#import "Logging.h"
#else
#define Warn NSLog
#define Log NSLog
#endif


#define kPortNumber 59840


static NSString* GetServerPath() {
    NSString* bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (!bundleID)
        bundleID = @"com.couchbase.TouchServ";
    
    NSArray* paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                         NSUserDomainMask, YES);
    NSString* path = paths[0];
    path = [path stringByAppendingPathComponent: bundleID];
    path = [path stringByAppendingPathComponent: @"TouchDB"];
    NSError* error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath: path
                                  withIntermediateDirectories: YES
                                                   attributes: nil error: &error]) {
        NSLog(@"FATAL: Couldn't create TouchDB server dir at %@", path);
        exit(1);
    }
    return path;
}


static bool doReplicate( TD_Server* server, const char* replArg,
                        BOOL pull, BOOL createTarget, BOOL continuous,
                        const char *user, const char *password)
{
    NSURL* remote = CFBridgingRelease(CFURLCreateWithBytes(NULL, (const UInt8*)replArg,
                                                           strlen(replArg),
                                                           kCFStringEncodingUTF8, NULL));
    if (!remote || !remote.scheme) {
        fprintf(stderr, "Invalid remote URL <%s>\n", replArg);
        return false;
    }
    NSString* dbName = remote.lastPathComponent;
    if (dbName.length == 0) {
        fprintf(stderr, "Invalid database name '%s'\n", dbName.UTF8String);
        return false;
    }

    if (user && password) {
        NSString* userStr = @(user);
        NSString* passStr = @(password);
        Log(@"Setting credentials for user '%@'", userStr);
        NSURLCredential* cred;
        cred = [NSURLCredential credentialWithUser: userStr
                                          password: passStr
                                       persistence: NSURLCredentialPersistenceForSession];
        int port = remote.port.intValue;
        if (port == 0)
            port = [remote.scheme isEqualToString: @"https"] ? 443 : 80;
        NSURLProtectionSpace* space;
        space = [[NSURLProtectionSpace alloc] initWithHost: remote.host
                                                      port: port
                                                  protocol: remote.scheme
                                                     realm: nil
                                      authenticationMethod: NSURLAuthenticationMethodDefault];
        [[NSURLCredentialStorage sharedCredentialStorage] setDefaultCredential: cred
                                                            forProtectionSpace: space];
    }
    
    if (pull)
        Log(@"Pulling from <%@> --> %@ ...", remote, dbName);
    else
        Log(@"Pushing %@ --> <%@> ...", dbName, remote);
    
    [server tellDatabaseManager: ^(TD_DatabaseManager *dbm) {
        TDReplicator* repl = nil;
        TD_Database* db = [dbm existingDatabaseNamed: dbName];
        if (pull) {
            if (db) {
                if (![db deleteDatabase: nil]) {
                    fprintf(stderr, "Couldn't delete existing database '%s'\n", dbName.UTF8String);
                    return;
                }
            }
            db = [dbm databaseNamed: dbName];
        }
        if (!db) {
            fprintf(stderr, "No such database '%s'\n", dbName.UTF8String);
            return;
        }
        [db open];
        repl = [db replicatorWithRemoteURL: remote push: !pull continuous: continuous];
        if (createTarget && !pull)
            ((TDPusher*)repl).createTarget = YES;
        if (!repl)
            fprintf(stderr, "Unable to create replication.\n");
        [repl start];
    }];
        
    return true;
}


int main (int argc, const char * argv[])
{
    @autoreleasepool {
#if DEBUG
        EnableLog(YES);
        EnableLogTo(TDListener, YES);
#endif

        TD_DatabaseManagerOptions options = kTD_DatabaseManagerDefaultOptions;
        const char* replArg = NULL, *user = NULL, *password = NULL;
        BOOL auth = NO, pull = NO, createTarget = NO, continuous = NO;
        
        for (int i = 1; i < argc; ++i) {
            if (strcmp(argv[i], "--readonly") == 0) {
                options.readOnly = YES;
            } else if (strcmp(argv[i], "--auth") == 0) {
                auth = YES;
            } else if (strcmp(argv[i], "--pull") == 0) {
                replArg = argv[++i];
                pull = YES;
            } else if (strcmp(argv[i], "--push") == 0) {
                replArg = argv[++i];
            } else if (strcmp(argv[i], "--create-target") == 0) {
                createTarget = YES;
            } else if (strcmp(argv[i], "--continuous") == 0) {
                continuous = YES;
            } else if (strcmp(argv[i], "--user") == 0) {
                user = argv[++i];
            } else if (strcmp(argv[i], "--password") == 0) {
                password = argv[++i];
            }
        }

        NSError* error;
        TD_Server* server = [[TD_Server alloc] initWithDirectory: GetServerPath()
                                                       options: &options
                                                         error: &error];
        if (error) {
            Warn(@"FATAL: Error initializing TouchDB: %@", error);
            exit(1);
        }
        [TDURLProtocol setServer: server];
        
        // Start a listener socket:
        TDListener* listener = [[TDListener alloc] initWithTDServer: server port: kPortNumber];
        listener.readOnly = options.readOnly;

        if (auth) {
            srandomdev();
            NSString* password = [NSString stringWithFormat: @"%lx", random()];
            listener.passwords = @{@"touchdb": password};
            Log(@"Auth required: user='touchdb', password='%@'", password);
        }

        // Advertise via Bonjour, and set a TXT record just as an example:
        [listener setBonjourName: @"TouchServ" type: @"_touchdb._tcp."];
        NSData* value = [@"value" dataUsingEncoding: NSUTF8StringEncoding];
        listener.TXTRecordDictionary = @{@"Key": value};
        
        [listener start];
        
        if (replArg) {
            if (!doReplicate(server, replArg, pull, createTarget, continuous, user, password))
                return 1;
        } else {
            Log(@"TouchServ %@ is listening%@ on port %d ... relax!",
                TDVersionString(),
                (listener.readOnly ? @" in read-only mode" : @""),
                listener.port);
        }
        
        [[NSRunLoop currentRunLoop] run];
        
        Log(@"TouchServ quitting");
    }
    return 0;
}

