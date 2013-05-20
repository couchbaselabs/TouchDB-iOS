//
//  TDChangeTracker.h
//  TouchDB
//
//  Created by Jens Alfke on 6/20/11.
//  Copyright 2011 Couchbase, Inc.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import <Foundation/Foundation.h>
@class TDChangeTracker;
@protocol TDAuthorizer;


@protocol TDChangeTrackerClient <NSObject>
@optional
- (void) changeTrackerReceivedChange: (NSDictionary*)change;
- (void) changeTrackerReceivedChanges: (NSArray*)changes;
- (void) changeTrackerStopped: (TDChangeTracker*)tracker;
@end


typedef enum TDChangeTrackerMode {
    kOneShot,
    kLongPoll,
    kContinuous
} TDChangeTrackerMode;


/** Reads the continuous-mode _changes feed of a database, and sends the individual change entries to its client.  */
@interface TDChangeTracker : NSObject <NSStreamDelegate>
{
    @protected
    NSURL* _databaseURL;
    id<TDChangeTrackerClient> __weak _client;
    TDChangeTrackerMode _mode;
    id _lastSequenceID;
    unsigned _limit;
    NSError* _error;
    BOOL _includeConflicts;
    NSString* _filterName;
    NSDictionary* _filterParameters;
    NSTimeInterval _heartbeat;
    NSDictionary* _requestHeaders;
    id<TDAuthorizer> _authorizer;
    unsigned _retryCount;
}

- (id)initWithDatabaseURL: (NSURL*)databaseURL
                     mode: (TDChangeTrackerMode)mode
                conflicts: (BOOL)includeConflicts
             lastSequence: (id)lastSequenceID
                   client: (id<TDChangeTrackerClient>)client;

@property (readonly, nonatomic) NSURL* databaseURL;
@property (readonly, nonatomic) NSString* databaseName;
@property (readonly) NSURL* changesFeedURL;
@property (readonly, copy, nonatomic) id lastSequenceID;
@property (strong, nonatomic) NSError* error;
@property (weak, nonatomic) id<TDChangeTrackerClient> client;
@property (strong, nonatomic) NSDictionary *requestHeaders;
@property (strong, nonatomic) id<TDAuthorizer> authorizer;

@property (nonatomic) TDChangeTrackerMode mode;
@property (copy) NSString* filterName;
@property (copy) NSDictionary* filterParameters;
@property (nonatomic) unsigned limit;
@property (nonatomic) NSTimeInterval heartbeat;
@property (nonatomic) NSArray *docIDs;

- (BOOL) start;
- (void) stop;

/** Asks the tracker to retry connecting, _if_ it's currently disconnected but waiting to retry.
    This should be called when the reachability of the remote host changes, or when the
    app is reactivated. */
- (void) retry;

// Protected
@property (readonly) NSString* changesFeedPath;
- (void) setUpstreamError: (NSString*)message;
- (void) failedWithError: (NSError*)error;
- (NSInteger) receivedPollResponse: (NSData*)body errorMessage: (NSString**)errorMessage;
- (BOOL) receivedChanges: (NSArray*)changes errorMessage: (NSString**)errorMessage;
- (BOOL) receivedChange: (NSDictionary*)change;
- (void) stopped; // override this

@end
