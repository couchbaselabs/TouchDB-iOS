//
//  TDPuller_Tests.m
//  TouchDB
//
//  Created by Jens Alfke on 12/7/11.
//  Copyright (c) 2011 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "TDPuller.h"
#import "TDServer.h"
#import "TDDatabase.h"
#import "TDInternal.h"
#import "Test.h"


#if XXXDEBUG

static id pull(TDDatabase* db, NSString* urlStr, id lastSequence) {
    NSURL* remote = [NSURL URLWithString: urlStr];
    TDReplicator* puller = [[[TDReplicator alloc] initWithDB: db remote: remote push: NO continuous: NO] autorelease];
    [puller start];
    
    CAssert(puller.running);
    Log(@"Waiting for puller to finish...");
    while (puller.running) {
        if (![[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
                                      beforeDate: [NSDate dateWithTimeIntervalSinceNow: 0.5]])
            break;
    }
    CAssert(!puller.running);
    return puller.lastSequence;
}


TestCase(TDPuller) {
    RequireTestCase(TDDatabase);
    TDServer* server = [TDServer createEmptyAtPath: @"/tmp/TDPullerTest"];
    TDDatabase* db = [server databaseNamed: @"db"];
    [db open];
    
    NSString* remoteURLStr = @"http://snej.iriscouch.com/tdpuller_test1";
    
    id lastSeq = pull(db, remoteURLStr, nil);
    CAssertEqual(lastSeq, @"6");
    
    CAssertEq(db.documentCount, 3u);
    CAssertEq(db.lastSequence, 10);
    
    pull(db, remoteURLStr, lastSeq);
    
    CAssertEq(db.lastSequence, 10);
}

#endif
