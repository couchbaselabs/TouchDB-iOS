//
//  TDDatabase+Replication.m
//  TouchDB
//
//  Created by Jens Alfke on 12/27/11.
//  Copyright (c) 2011 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "TDDatabase.h"
#import "TDInternal.h"

#import "FMDatabase.h"
#import "FMDatabaseAdditions.h"


@implementation TDDatabase (Replication)


- (NSArray*) activeReplicators {
    return _activeReplicators;
}

- (TDReplicator*) activeReplicatorWithRemoteURL: (NSURL*)remote
                                           push: (BOOL)push {
    TDReplicator* repl;
    for (repl in _activeReplicators) {
        if ($equal(repl.remote, remote) && repl.isPush == push)
            return repl;
    }
    return nil;
}

- (TDReplicator*) replicateWithRemoteURL: (NSURL*)remote
                                    push: (BOOL)push
                              continuous: (BOOL)continuous {
    TDReplicator* repl = [self activeReplicatorWithRemoteURL: remote push: push];
    if (repl)
        return repl;
    repl = [[TDReplicator alloc] initWithDB: self
                                     remote: remote 
                                       push: push
                                 continuous: continuous];
    if (!repl)
        return nil;
    if (!_activeReplicators)
        _activeReplicators = [[NSMutableArray alloc] init];
    [_activeReplicators addObject: repl];
    [repl start];
    [repl release];
    return repl;
}

- (void) replicatorDidStop: (TDReplicator*)repl {
    [_activeReplicators removeObjectIdenticalTo: repl];
}


- (NSString*) lastSequenceWithRemoteURL: (NSURL*)url push: (BOOL)push {
    return [_fmdb stringForQuery:@"SELECT last_sequence FROM replicators WHERE remote=? AND push=?",
                                 url.absoluteString, $object(push)];
}

- (BOOL) setLastSequence: (NSString*)lastSequence withRemoteURL: (NSURL*)url push: (BOOL)push {
    return [_fmdb executeUpdate: 
            @"INSERT OR REPLACE INTO replicators (remote, push, last_sequence) VALUES (?, ?, ?)",
            url.absoluteString, $object(push), lastSequence];
}


static NSString* quote(NSString* str) {
    return [str stringByReplacingOccurrencesOfString: @"'" withString: @"''"];
}

+ (NSString*) joinQuotedStrings: (NSArray*)strings {
    if (strings.count == 0)
        return @"";
    NSMutableString* result = [NSMutableString stringWithString: @"'"];
    BOOL first = YES;
    for (NSString* str in strings) {
        if (first)
            first = NO;
        else
            [result appendString: @"','"];
        [result appendString: quote(str)];
    }
    [result appendString: @"'"];
    return result;
}


- (BOOL) findMissingRevisions: (TDRevisionList*)revs {
    if (revs.count == 0)
        return YES;
    NSString* sql = $sprintf(@"SELECT docid, revid FROM revs, docs "
                              "WHERE revid in (%@) AND docid IN (%@) "
                              "AND revs.doc_id == docs.doc_id",
                             [TDDatabase joinQuotedStrings: revs.allRevIDs],
                             [TDDatabase joinQuotedStrings: revs.allDocIDs]);
    // ?? Not sure sqlite will optimize this fully. May need a first query that looks up all
    // the numeric doc_ids from the docids.
    FMResultSet* r = [_fmdb executeQuery: sql];
    if (!r)
        return NO;
    while ([r next]) {
        @autoreleasepool {
            TDRevision* rev = [revs revWithDocID: [r stringForColumnIndex: 0]
                                           revID: [r stringForColumnIndex: 1]];
            if (rev)
                [revs removeRev: rev];
        }
    }
    [r close];
    return YES;
}


@end
