//
//  TDPusher.m
//  TouchDB
//
//  Created by Jens Alfke on 12/5/11.
//  Copyright (c) 2011 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "TDPusher.h"
#import "TDDatabase.h"
#import "TDDatabase+Insertion.h"
#import "TDRevision.h"
#import "TDMultipartUploader.h"
#import "TDInternal.h"
#import "TDMisc.h"


static int findCommonAncestor(TDRevision* rev, NSArray* possibleIDs);
static void stubOutAttachmentsBeforeRevPos(TDRevision* rev, int minRevPos);


@interface TDPusher ()
- (BOOL) uploadMultipartRevision: (TDRevision*)rev;
@end


@implementation TDPusher


@synthesize createTarget=_createTarget, filter=_filter;


- (void)dealloc {
    [_filter release];
    [super dealloc];
}


- (BOOL) isPush {
    return YES;
}


// This is called before beginReplicating, if the target db might not exist
- (void) maybeCreateRemoteDB {
    if (!_createTarget)
        return;
    LogTo(Sync, @"Remote db might not exist; creating it...");
    [self asyncTaskStarted];
    [self sendAsyncRequest: @"PUT" path: @"" body: nil onCompletion: ^(id result, NSError* error) {
        if (error && error.code != 412) {
            LogTo(Sync, @"Failed to create remote db: %@", error);
            self.error = error;
            [self stop];
        } else {
            LogTo(Sync, @"Created remote db");
            _createTarget = NO;
            [self beginReplicating];
        }
        [self asyncTasksFinished: 1];
    }];
}


- (void) beginReplicating {
    // If we're still waiting to create the remote db, do nothing now. (This method will be
    // re-invoked after that request finishes; see -maybeCreateRemoteDB above.)
    if (_createTarget)
        return;
    
    // Include conflicts so all conflicting revisions are replicated too
    TDChangesOptions options = kDefaultTDChangesOptions;
    options.includeConflicts = YES;
    // Process existing changes since the last push:
    TDRevisionList* changes = [_db changesSinceSequence: [_lastSequence longLongValue] 
                                                options:&options filter: _filter];
    if (changes.count > 0)
        [self processInbox: changes];
    
    // Now listen for future changes (in continuous mode):
    if (_continuous) {
        _observing = YES;
        [[NSNotificationCenter defaultCenter] addObserver: self selector: @selector(dbChanged:)
                                                     name: TDDatabaseChangeNotification object: _db];
        [self asyncTaskStarted];  // prevents -stopped from being called when other tasks finish
    }
}

- (void) stop {
    if (_observing) {
        _observing = NO;
        [[NSNotificationCenter defaultCenter] removeObserver: self];
        [self asyncTasksFinished: 1];
    }
    [super stop];
}

- (void) dbChanged: (NSNotification*)n {
    NSDictionary* userInfo = n.userInfo;
    // Skip revisions that originally came from the database I'm syncing to:
    if ([[userInfo objectForKey: @"source"] isEqual: _remote])
        return;
    TDRevision* rev = [userInfo objectForKey: @"rev"];
    if (!_filter || _filter(rev))
        [self addToInbox: rev];
}


- (void) processInbox: (TDRevisionList*)changes {
    // Generate a set of doc/rev IDs in the JSON format that _revs_diff wants:
    NSMutableDictionary* diffs = $mdict();
    for (TDRevision* rev in changes) {
        NSString* docID = rev.docID;
        NSMutableArray* revs = [diffs objectForKey: docID];
        if (!revs) {
            revs = $marray();
            [diffs setObject: revs forKey: docID];
        }
        [revs addObject: rev.revID];
    }
    
    // Call _revs_diff on the target db:
    [self asyncTaskStarted];
    [self sendAsyncRequest: @"POST" path: @"/_revs_diff" body: diffs
              onCompletion:^(NSDictionary* results, NSError* error) {
        if (error) {
            self.error = error;
            [self stop];
        } else if (results.count) {
            // Go through the list of local changes again, selecting the ones the destination server
            // said were missing and mapping them to a JSON dictionary in the form _bulk_docs wants:
            __block SequenceNumber lastInboxSequence = 0;
            NSArray* docsToSend = [changes.allRevisions my_map: ^(TDRevision* rev) {
                NSDictionary* properties;
                @autoreleasepool {
                    // Is this revision in the server's 'missing' list?
                    NSDictionary* revResults = [results objectForKey: [rev docID]];
                    NSArray* missing = [revResults objectForKey: @"missing"];
                    if (![missing containsObject: [rev revID]])
                        return (id)nil;
                    
                    // Get the revision's properties:
                    if ([rev deleted]) {
                        properties = $mdict({@"_id", [rev docID]},
                                            {@"_rev", [rev revID]}, 
                                            {@"_deleted", $true},
                                            {@"_revisions", [_db getRevisionHistoryDict: rev]});
                        [properties retain];
                    } else {
                        if ([_db loadRevisionBody: rev
                                          options: kTDIncludeAttachments | kTDBigAttachmentsFollow |
                                                   kTDIncludeRevs]
                                    >= 300) {
                            Warn(@"%@: Couldn't get local contents of %@", self, rev);
                            return nil;
                        }
                        // Strip any attachments already known to the target db:
                        if ([rev.properties objectForKey: @"_attachments"]) {
                            // Look for the latest common ancestor:
                            NSArray* possible = [revResults objectForKey: @"possible_ancestors"];
                            int minRevPos = findCommonAncestor(rev, possible);
                            if (minRevPos > 0)
                                stubOutAttachmentsBeforeRevPos(rev, minRevPos + 1);
                            // If the rev has huge attachments, send it under separate cover:
                            if ([self uploadMultipartRevision: rev])
                                return nil;
                        }
                        properties = [[rev properties] copy];
                    }
                }
                lastInboxSequence = rev.sequence;
                Assert([properties objectForKey: @"_id"]);
                return [properties autorelease];
            }];
            
            // Post the revisions to the destination. "new_edits":false means that the server should
            // use the given _rev IDs instead of making up new ones.
            NSUInteger numDocsToSend = docsToSend.count;
            if (numDocsToSend > 0) {
                LogTo(Sync, @"%@: Sending %u revisions", self, numDocsToSend);
                LogTo(SyncVerbose, @"%@: Sending %@", self, changes.allRevisions);
                self.changesTotal += numDocsToSend;
                [self asyncTaskStarted];
                [self sendAsyncRequest: @"POST"
                             path: @"/_bulk_docs"
                             body: $dict({@"docs", docsToSend},
                                         {@"new_edits", $false})
                     onCompletion: ^(NSDictionary* response, NSError *error) {
                         if (error) {
                             self.error = error;
                         } else {
                             LogTo(SyncVerbose, @"%@: Sent %@", self, changes.allRevisions);
                             self.lastSequence = $sprintf(@"%lld", lastInboxSequence);
                         }
                         self.changesProcessed += numDocsToSend;
                         [self asyncTasksFinished: 1];
                     }
                 ];
            }
            
        } else {
            // If none of the revisions are new to the remote, just bump the lastSequence:
            self.lastSequence = $sprintf(@"%lld", [changes.allRevisions.lastObject sequence]);
        }
        [self asyncTasksFinished: 1];
    }];
}


- (BOOL) uploadMultipartRevision: (TDRevision*)rev {
    // Find all the attachments with "follows" instead of a body, and put 'em in a multipart stream:
    TDMultipartWriter* bodyStream = nil;
    NSDictionary* attachments = [rev.properties objectForKey: @"_attachments"];
    for (NSDictionary* attachment in attachments.allValues) {
        if ([attachment objectForKey: @"follows"]) {
            if (!bodyStream) {
                // Create the HTTP multipart stream:
                bodyStream = [[[TDMultipartWriter alloc] initWithContentType: @"multipart/related"
                                                                      boundary: nil] autorelease];
                [bodyStream setNextPartsHeaders: $dict({@"Content-Type", @"application/json"})];
                [bodyStream addData: rev.asJSON];
            }
            UInt64 length;
            NSInputStream *stream = [_db inputStreamForAttachmentDict: attachment length: &length];
            [bodyStream addStream: stream length: length];
        }
    }
    if (!bodyStream)
        return NO;
    
    // OK, we are going to upload this on its own:
    self.changesTotal++;
    [self asyncTaskStarted];

    NSString* path = $sprintf(@"/%@?new_edits=false", TDEscapeURLParam(rev.docID));
    LogTo(SyncVerbose, @"%@: PUT .%@ (multipart, %lldkb)", self, path, bodyStream.length/1024);
    NSString* urlStr = [_remote.absoluteString stringByAppendingString: path];
    [[[TDMultipartUploader alloc] initWithURL: [NSURL URLWithString: urlStr]
                                     streamer: bodyStream
                                 onCompletion: ^(id response, NSError *error) {
                  if (error) {
                      self.error = error;
                  } else {
                      LogTo(SyncVerbose, @"%@: Sent %@, response=%@", self, rev, response);
                      self.lastSequence = $sprintf(@"%lld", rev.sequence);
                  }
                  self.changesProcessed++;
                  [self asyncTasksFinished: 1];
              }
     ] autorelease];
    return YES;
}


// Given a revision and an array of revIDs, finds the latest common ancestor revID
// and returns its generation #. If there is none, returns 0.
static int findCommonAncestor(TDRevision* rev, NSArray* possibleRevIDs) {
    if (possibleRevIDs.count == 0)
        return 0;
    NSArray* history = [TDDatabase parseCouchDBRevisionHistory: rev.properties];
    NSString* ancestorID = [history firstObjectCommonWithArray: possibleRevIDs];
    if (!ancestorID)
        return 0;
    int generation;
    if (![TDDatabase parseRevID: ancestorID intoGeneration: &generation andSuffix: nil])
        generation = 0;
    return generation;
}


// Turns attachments whose revpos is less than the minRevPos into stubs.
static void stubOutAttachmentsBeforeRevPos(TDRevision* rev, int minRevPos) {
    NSDictionary* properties = rev.properties;
    NSMutableDictionary* editedProperties = nil;
    NSDictionary* attachments = (id)[properties objectForKey: @"_attachments"];
    NSMutableDictionary* editedAttachments = nil;
    for (NSString* name in attachments) {
        NSDictionary* attachment = [attachments objectForKey: name];
        int revPos = [[attachment objectForKey: @"revpos"] intValue];
        if (revPos > 0 && revPos < minRevPos && ![attachment objectForKey: @"stub"]) {
            // Strip this attachment's body. First make its dictionary mutable:
            if (!editedProperties) {
                editedProperties = [[properties mutableCopy] autorelease];
                editedAttachments = [[attachments mutableCopy] autorelease];
                [editedProperties setObject: editedAttachments forKey: @"_attachments"];
            }
            // ...then remove the 'data' and 'follows' key:
            NSMutableDictionary* editedAttachment = [[attachment mutableCopy] autorelease];
            [editedAttachment removeObjectForKey: @"data"];
            [editedAttachment removeObjectForKey: @"follows"];
            [editedAttachment setObject: $true forKey: @"stub"];
            [editedAttachments setObject: editedAttachment forKey: name];
            LogTo(SyncVerbose, @"TDPusher: %@: Stubbed out attachment '%@': revpos %d < %d",
                  rev, name, revPos, minRevPos);
        }
    }
    
    if (editedProperties)
        rev.properties = editedProperties;
}


@end




TestCase(TDPusher_findCommonAncestor) {
    NSDictionary* revDict = $dict({@"ids", $array(@"second", @"first")}, {@"start", $object(2)});
    TDRevision* rev = [TDRevision revisionWithProperties: $dict({@"_revisions", revDict})];
    CAssertEq(findCommonAncestor(rev, $array()), 0);
    CAssertEq(findCommonAncestor(rev, $array(@"3-noway", @"1-nope")), 0);
    CAssertEq(findCommonAncestor(rev, $array(@"3-noway", @"1-first")), 1);
    CAssertEq(findCommonAncestor(rev, $array(@"3-noway", @"2-second", @"1-first")), 2);
}

TestCase(TDPusher_removeAttachmentsBeforeRevPos) {
    NSDictionary* hello = $dict({@"revpos", $object(1)}, {@"follows", $true});
    NSDictionary* goodbye = $dict({@"revpos", $object(2)}, {@"data", @"squeeee"});
    NSDictionary* attachments = $dict({@"hello", hello}, {@"goodbye", goodbye});
    
    TDRevision* rev = [TDRevision revisionWithProperties: $dict({@"_attachments", attachments})];
    stubOutAttachmentsBeforeRevPos(rev, 3);
    CAssertEqual(rev.properties, $dict({@"_attachments", $dict({@"hello", $dict({@"revpos", $object(1)}, {@"stub", $true})},
                                                               {@"goodbye", $dict({@"revpos", $object(2)}, {@"stub", $true})})}));
    
    rev = [TDRevision revisionWithProperties: $dict({@"_attachments", attachments})];
    stubOutAttachmentsBeforeRevPos(rev, 2);
    CAssertEqual(rev.properties, $dict({@"_attachments", $dict({@"hello", $dict({@"revpos", $object(1)}, {@"stub", $true})},
                                                               {@"goodbye", goodbye})}));
    
    rev = [TDRevision revisionWithProperties: $dict({@"_attachments", attachments})];
    stubOutAttachmentsBeforeRevPos(rev, 1);
    CAssertEqual(rev.properties, $dict({@"_attachments", attachments}));
}
