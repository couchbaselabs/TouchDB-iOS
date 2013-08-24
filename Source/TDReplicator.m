//
//  TDReplicator.m
//  TouchDB
//
//  Created by Jens Alfke on 12/6/11.
//  Copyright (c) 2011 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "TDReplicator.h"
#import "TDPusher.h"
#import "TDPuller.h"
#import "TD_Database+Replication.h"
#import "TDRemoteRequest.h"
#import "TDAuthorizer.h"
#import "TDBatcher.h"
#import "TDReachability.h"
#import "TDURLProtocol.h"
#import "TDInternal.h"
#import "TDMisc.h"
#import "TDBase64.h"
#import "TDCanonicalJSON.h"
#import "MYBlockUtils.h"
#import "MYURLUtils.h"


#define kProcessDelay 0.5
#define kInboxCapacity 100

#define kRetryDelay 60.0

#define kDefaultRequestTimeout 60.0


NSString* TDReplicatorProgressChangedNotification = @"TDReplicatorProgressChanged";
NSString* TDReplicatorStoppedNotification = @"TDReplicatorStopped";

#if TARGET_OS_IPHONE
@interface TDReplicator (Backgrounding)
- (void) setupBackgrounding;
- (void) endBackgrounding;
- (void) okToEndBackgrounding;
@end
#endif

@interface TDReplicator ()
@property (readwrite, nonatomic) BOOL running, active;
@property (readwrite, copy) NSDictionary* remoteCheckpoint;
- (void) updateActive;
- (void) fetchRemoteCheckpointDoc;
- (void) saveLastSequence;
@end


@implementation TDReplicator

+ (NSString *)progressChangedNotification
{
    return TDReplicatorProgressChangedNotification;
}

+ (NSString *)stoppedNotification
{
    return TDReplicatorStoppedNotification;
}


- (id) initWithDB: (TD_Database*)db
           remote: (NSURL*)remote
             push: (BOOL)push
       continuous: (BOOL)continuous
{
    NSParameterAssert(db);
    NSParameterAssert(remote);
    
    // TDReplicator is an abstract class; instantiating one actually instantiates a subclass.
    if ([self class] == [TDReplicator class]) {
        Class klass = push ? [TDPusher class] : [TDPuller class];
        return [[klass alloc] initWithDB: db remote: remote push: push continuous: continuous];
    }
    
    self = [super init];
    if (self) {
        _thread = [NSThread currentThread];
        _db = db;
        _remote = remote;
        _continuous = continuous;
        Assert(push == self.isPush);

        static int sLastSessionID = 0;
        _sessionID = [$sprintf(@"repl%03d", ++sLastSessionID) copy];
    }
    return self;
}


- (void)dealloc {
    [self stop];
    [[NSNotificationCenter defaultCenter] removeObserver: self];
    [_host stop];
}


- (void) clearDbRef {
    // If we're in the middle of saving the checkpoint and waiting for a response, by the time the
    // response arrives _db will be nil, so there won't be any way to save the checkpoint locally.
    // To avoid that, pre-emptively save the local checkpoint now.
    if (_savingCheckpoint && _lastSequence)
        [_db setLastSequence: _lastSequence withCheckpointID: self.remoteCheckpointDocID];
    _db = nil;
}


- (void) databaseClosing {
    [self saveLastSequence];
    [self stop];
    [self clearDbRef];
}


- (NSString*) description {
    return $sprintf(@"%@[%@]", [self class], _remote.absoluteString);
}


@synthesize db=_db, remote=_remote, filterName=_filterName, filterParameters=_filterParameters, docIDs = _docIDs;
@synthesize running=_running, online=_online, active=_active, continuous=_continuous;
@synthesize error=_error, sessionID=_sessionID, options=_options;
@synthesize changesProcessed=_changesProcessed, changesTotal=_changesTotal;
@synthesize remoteCheckpoint=_remoteCheckpoint;
@synthesize authorizer=_authorizer;
@synthesize requestHeaders = _requestHeaders;


- (BOOL) isPush {
    return NO;  // guess who overrides this?
}


- (bool) hasSameSettingsAs: (TDReplicator*)other {
    return _db == other->_db && $equal(_remote, other->_remote) && self.isPush == other.isPush
        && _continuous == other->_continuous && $equal(_filterName, other->_filterName)
        && $equal(_filterParameters, other->_filterParameters) && $equal(_options, other->_options) && $equal(_docIDs, other->_docIDs)
        && $equal(_requestHeaders, other->_requestHeaders);
}


- (NSString*) lastSequence {
    return _lastSequence;
}

- (void) setLastSequence:(NSString*)lastSequence {
    if (!$equal(lastSequence, _lastSequence)) {
        LogTo(SyncVerbose, @"%@: Setting lastSequence to %@ (from %@)",
              self, lastSequence, _lastSequence);
        _lastSequence = [lastSequence copy];
        if (!_lastSequenceChanged) {
            _lastSequenceChanged = YES;
            [self performSelector: @selector(saveLastSequence) withObject: nil afterDelay: 5.0];
        }
    }
}


- (void) postProgressChanged {
    LogTo(Sync, @"%@: postProgressChanged (%u/%u, active=%d (batch=%u, net=%u), online=%d)", 
          self, (unsigned)_changesProcessed, (unsigned)_changesTotal,
          _active, (unsigned)_batcher.count, _asyncTaskCount, _online);
    NSNotification* n = [NSNotification notificationWithName: TDReplicatorProgressChangedNotification
                                                      object: self];
    [[NSNotificationQueue defaultQueue] enqueueNotification: n
                                               postingStyle: NSPostWhenIdle
                                               coalesceMask: NSNotificationCoalescingOnSender |
                                                             NSNotificationCoalescingOnName
                                                   forModes: nil];
}


- (void) setChangesProcessed: (NSUInteger)processed {
    _changesProcessed = processed;
    [self postProgressChanged];
}

- (void) setChangesTotal: (NSUInteger)total {
    _changesTotal = total;
    [self postProgressChanged];
}

- (void) setError:(NSError *)error {
    if (error.code == NSURLErrorCancelled && $equal(error.domain, NSURLErrorDomain))
        return;
    
    if (_error != error)
    {
        _error = error;
        [self postProgressChanged];
    }
}


- (void) start {
    if (_running)
        return;
    Assert(_db, @"Can't restart an already stopped TDReplicator");
    LogTo(Sync, @"%@ STARTING ...", self);

    [_db addActiveReplicator: self];

    // Did client request a reset (i.e. starting over from first sequence?)
    if (_options[@"reset"] != nil) {
        [_db setLastSequence: nil withCheckpointID: self.remoteCheckpointDocID];
    }

    // Note: This is actually a ref cycle, because the block has a (retained) reference to 'self',
    // and _batcher retains the block, and of course I retain _batcher.
    // The cycle is broken in -stopped when I release _batcher.
    _batcher = [[TDBatcher alloc] initWithCapacity: kInboxCapacity delay: kProcessDelay
                 processor:^(NSArray *inbox) {
                     LogTo(SyncVerbose, @"*** %@: BEGIN processInbox (%u sequences)",
                           self, (unsigned)inbox.count);
                     TD_RevisionList* revs = [[TD_RevisionList alloc] initWithArray: inbox];
                     [self processInbox: revs];
                     LogTo(SyncVerbose, @"*** %@: END processInbox (lastSequence=%@)", self, _lastSequence);
                     [self updateActive];
                 }
                ];

    // If client didn't set an authorizer, use basic auth if credential is available:
    if (!_authorizer) {
        _authorizer = [[TDBasicAuthorizer alloc] initWithURL: _remote];
        if (_authorizer)
            LogTo(SyncVerbose, @"%@: Found credential, using %@", self, _authorizer);
    }

    self.running = YES;
    _startTime = CFAbsoluteTimeGetCurrent();
    
#if TARGET_OS_IPHONE
    [self setupBackgrounding];
#endif
    
    _online = NO;
    if ([TDURLProtocol handlesURL: _remote]) {
        [self goOnline];    // local-to-local replication
    } else {
        // Start reachability checks. (This creates another ref cycle, because
        // the block also retains a ref to self. Cycle is also broken in -stopped.)
        _host = [[TDReachability alloc] initWithHostName: _remote.host];
        
        __weak id weakSelf = self;
        _host.onChange = ^{
            TDReplicator *strongSelf = weakSelf;
            [strongSelf reachabilityChanged:strongSelf->_host];
        };
        [_host start];
        [self reachabilityChanged: _host];
    }
}


- (void) beginReplicating {
    // Subclasses implement this
}


- (void) stop {
    if (!_running)
        return;
    LogTo(Sync, @"%@ STOPPING...", self);
    [_batcher flushAll];
    _continuous = NO;

    [self stopRemoteRequests];
    [NSObject cancelPreviousPerformRequestsWithTarget: self
                                             selector: @selector(retryIfReady) object: nil];
    if (_running && _asyncTaskCount == 0)
        [self stopped];
}


- (void) stopped {
    LogTo(Sync, @"%@ STOPPED", self);
    Log(@"Replication: %@ took %.3f sec; error=%@",
        self, CFAbsoluteTimeGetCurrent()-_startTime, _error);
    
    #if TARGET_OS_IPHONE
            [self endBackgrounding];
    #endif
    
    self.running = NO;
    self.changesProcessed = self.changesTotal = 0;
    [[NSNotificationCenter defaultCenter]
        postNotificationName: TDReplicatorStoppedNotification object: self];
    [self saveLastSequence];
    
    _batcher = nil;
    [_host stop];
    _host = nil;
    [self clearDbRef];  // _db no longer tracks me so it won't notify me when it closes; clear ref now
}


// Called after a continuous replication has gone idle, but it failed to transfer some revisions
// and so wants to try again in a minute. Should be overridden by subclasses.
- (void) retry {
}

- (void) retryIfReady {
    if (!_running)
        return;

    if (_online) {
        LogTo(Sync, @"%@ RETRYING, to transfer missed revisions...", self);
        _revisionsFailed = 0;
        [NSObject cancelPreviousPerformRequestsWithTarget: self
                                                 selector: @selector(retryIfReady) object: nil];
        [self retry];
    } else {
        [self performSelector: @selector(retryIfReady) withObject: nil afterDelay: kRetryDelay];
    }
}


- (BOOL) goOffline {
    if (!_online)
        return NO;
    LogTo(Sync, @"%@: Going offline", self);
    _online = NO;
    [self stopRemoteRequests];
    [self postProgressChanged];
    return YES;
}


- (BOOL) goOnline {
    if (_online)
        return NO;
    LogTo(Sync, @"%@: Going online", self);
    _online = YES;

    if (_running) {
        _lastSequence = nil;
        self.error = nil;

        [self checkSession];
        [self postProgressChanged];
    }
    return YES;
}


- (void) reachabilityChanged: (TDReachability*)host {
    LogTo(Sync, @"%@: Reachability state = %@ (%02X)", self, host, host.reachabilityFlags);

    if (host.reachable)
        [self goOnline];
    else if (host.reachabilityKnown)
        [self goOffline];
}


- (void) updateActive {
    BOOL active = _batcher.count > 0 || _asyncTaskCount > 0;
    if (active != _active) {
        self.active = active;
        [self postProgressChanged];
        if (!_active) {
            // Replicator is now idle. If it's not continuous, stop.
            #if TARGET_OS_IPHONE
                            [self okToEndBackgrounding];
            #endif
            
            if (!_continuous) {
                [self stopped];
            } else if (_revisionsFailed > 0) {
                LogTo(Sync, @"%@: Failed to xfer %u revisions; will retry in %g sec",
                      self, _revisionsFailed, kRetryDelay);
                [NSObject cancelPreviousPerformRequestsWithTarget: self
                                                         selector: @selector(retryIfReady)
                                                           object: nil];
                [self performSelector: @selector(retryIfReady)
                           withObject: nil afterDelay: kRetryDelay];
            }
        }
    }
}


- (void) asyncTaskStarted {
    if (_asyncTaskCount++ == 0)
        [self updateActive];
}


- (void) asyncTasksFinished: (NSUInteger)numTasks {
    _asyncTaskCount -= numTasks;
    Assert(_asyncTaskCount >= 0);
    if (_asyncTaskCount == 0) {
        [self updateActive];
    }
}


- (void) addToInbox: (TD_Revision*)rev {
    Assert(_running);
    [_batcher queueObject: rev];
    [self updateActive];
}


- (void) addRevsToInbox: (TD_RevisionList*)revs {
    Assert(_running);
    LogTo(SyncVerbose, @"%@: Received %llu revs", self, (UInt64)revs.count);
    [_batcher queueObjects: revs.allRevisions];
    [self updateActive];
}


- (void) processInbox: (NSArray*)inbox {
}


- (void) revisionFailed {
    // Remember that some revisions failed to transfer, so we can later retry.
    ++_revisionsFailed;
}


// Before doing anything else, determine whether we have an active login session.
- (void) checkSession {
    if (![_authorizer respondsToSelector: @selector(loginParametersForSite:)]) {
        [self fetchRemoteCheckpointDoc];
        return;
    }

    // First check whether a session exists
    [self asyncTaskStarted];
    [self sendAsyncRequest: @"GET"
                      path: @"/_session"
                      body: nil
              onCompletion: ^(id result, NSError *error) {
                  if (error) {
                      LogTo(Sync, @"%@: Session check failed: %@", self, error);
                      self.error = error;
                  } else {
                      NSString* username = $castIf(NSString, [[result objectForKey: @"userCtx"] objectForKey: @"name"]);
                      if (username) {
                          LogTo(Sync, @"%@: Active session, logged in as '%@'", self, username);
                          [self fetchRemoteCheckpointDoc];
                      } else {
                          [self login];
                      }
                  }
                  [self asyncTasksFinished: 1];
              }
     ];
}


// If there is no login session, attempt to log in, if the authorizer knows the parameters.
- (void) login {
    NSDictionary* loginParameters = [_authorizer loginParametersForSite: _remote];
    if (loginParameters == nil) {
        LogTo(Sync, @"%@: Authorizer has no login parameters, so skipping login", self);
        [self fetchRemoteCheckpointDoc];
        return;
    }

    NSString* loginPath = [_authorizer loginPathForSite: _remote];
    LogTo(Sync, @"%@: Logging in with %@ at %@ ...", self, _authorizer.class, loginPath);
    [self asyncTaskStarted];
    [self sendAsyncRequest: @"POST"
                      path: loginPath
                      body: loginParameters
              onCompletion: ^(id result, NSError *error) {
                  if (error) {
                      LogTo(Sync, @"%@: Login failed!", self);
                      self.error = error;
                  } else {
                      LogTo(Sync, @"%@: Successfully logged in!", self);
                      [self fetchRemoteCheckpointDoc];
                  }
                  [self asyncTasksFinished: 1];
              }
     ];
}


#pragma mark - HTTP REQUESTS:


- (NSTimeInterval) requestTimeout {
    id timeoutObj = _options[@"connection_timeout"];    // CouchDB specifies this name
    if (!timeoutObj)
        return kDefaultRequestTimeout;
    NSTimeInterval timeout = [timeoutObj doubleValue] / 1000.0;
    return timeout > 0.0 ? timeout : kDefaultRequestTimeout;
}


- (TDRemoteJSONRequest*) sendAsyncRequest: (NSString*)method
                                     path: (NSString*)path
                                     body: (id)body
                             onCompletion: (TDRemoteRequestCompletionBlock)onCompletion
{
    LogTo(SyncVerbose, @"%@: %@ %@", self, method, path);
    NSURL* url;
    if ([path hasPrefix: @"/"]) {
        url = [[NSURL URLWithString: path relativeToURL: _remote] absoluteURL];
    } else {
        url = TDAppendToURL(_remote, path);
    }
    onCompletion = [onCompletion copy];
    
    // under ARC, using variable req used directly inside the block results in a compiler error (it could have undefined value).
    __weak TDReplicator *weakSelf = self;
    __block TDRemoteJSONRequest *req = nil;
    req = [[TDRemoteJSONRequest alloc] initWithMethod: method
                                                  URL: url
                                                 body: body
                                       requestHeaders: self.requestHeaders
                                         onCompletion: ^(id result, NSError* error) {
        TDReplicator *strongSelf = weakSelf;
        [strongSelf removeRemoteRequest: req];
        id<TDAuthorizer> auth = req.authorizer;
        if (auth && auth != _authorizer && error.code != 401) {
            LogTo(SyncVerbose, @"%@: Updated to %@", self, auth);
            _authorizer = auth;
        }
        onCompletion(result, error);
    }];
    req.timeoutInterval = self.requestTimeout;
    req.authorizer = _authorizer;
    [self addRemoteRequest: req];
    [req start];
    return req;
}


- (void) addRemoteRequest: (TDRemoteRequest*)request {
    if (!_remoteRequests)
        _remoteRequests = [[NSMutableArray alloc] init];
    [_remoteRequests addObject: request];
}

- (void) removeRemoteRequest: (TDRemoteRequest*)request {
    [_remoteRequests removeObjectIdenticalTo: request];
}


- (void) stopRemoteRequests {
    if (!_remoteRequests)
        return;
    LogTo(Sync, @"Stopping %u remote requests", (unsigned)_remoteRequests.count);
    // Clear _remoteRequests before iterating, to ensure that re-entrant calls to this won't
    // try to re-stop any of the requests. (Re-entrant calls are possible due to replicator
    // error handling when it receives the 'canceled' errors from the requests I'm stopping.)
    NSArray* requests = _remoteRequests;
    _remoteRequests = nil;
    [requests makeObjectsPerformSelector: @selector(stop)];
}


- (NSArray*) activeRequestsStatus {
    return [_remoteRequests my_map: ^id(TDRemoteRequest* request) {
        return request.statusInfo;
    }];
}


#pragma mark - CHECKPOINT STORAGE:


- (void) maybeCreateRemoteDB {
    // TDPusher overrides this to implement the .createTarget option
}


/** This is the _local document ID stored on the remote server to keep track of state.
    It's based on the local database UUID (the private one, to make the result unguessable),
    the remote database's URL, and the filter name and parameters (if any). */
- (NSString*) remoteCheckpointDocID {
    NSMutableDictionary* spec = $mdict({@"localUUID", _db.privateUUID},
                                       {@"remoteURL", _remote.absoluteString},
                                       {@"push", @(self.isPush)},
                                       {@"filter", _filterName},
                                       {@"filterParams", _filterParameters});
    return TDHexSHA1Digest([TDCanonicalJSON canonicalData: spec]);
}


- (void) fetchRemoteCheckpointDoc {
    _lastSequenceChanged = NO;
    NSString* checkpointID = self.remoteCheckpointDocID;
    NSString* localLastSequence = [_db lastSequenceWithCheckpointID: checkpointID];
    
    [self asyncTaskStarted];
    TDRemoteJSONRequest* request = 
        [self sendAsyncRequest: @"GET"
                          path: [@"_local/" stringByAppendingString: checkpointID]
                          body: nil
                  onCompletion: ^(id response, NSError* error) {
                  // Got the response:
                  if (error && error.code != kTDStatusNotFound) {
                      LogTo(Sync, @"%@: Error fetching last sequence: %@", self, error.localizedDescription);
                      self.error = error;
                  } else {
                      if (error.code == kTDStatusNotFound)
                          [self maybeCreateRemoteDB];
                      response = $castIf(NSDictionary, response);
                      self.remoteCheckpoint = response;
                      NSString* remoteLastSequence = response[@"lastSequence"];

                      if ($equal(remoteLastSequence, localLastSequence)) {
                          _lastSequence = localLastSequence;
                          LogTo(Sync, @"%@: Replicating from lastSequence=%@", self, _lastSequence);
                      } else {
                          LogTo(Sync, @"%@: lastSequence mismatch: I had %@, remote had %@ (response = %@)",
                                self, localLastSequence, remoteLastSequence, response);
                      }
                      [self beginReplicating];
                  }
                  [self asyncTasksFinished: 1];
          }
     ];
    [request dontLog404];
}


#if DEBUG
@synthesize savingCheckpoint=_savingCheckpoint;  // for unit tests
#endif


- (void) saveLastSequence {
    if (!_lastSequenceChanged)
        return;
    if (_savingCheckpoint) {
        // If a save is already in progress, don't do anything. (The completion block will trigger
        // another save after the first one finishes.)
        _overdueForSave = YES;
        return;
    }
    _lastSequenceChanged = _overdueForSave = NO;
    
    LogTo(Sync, @"%@ checkpointing sequence=%@", self, _lastSequence);
    NSMutableDictionary* body = [_remoteCheckpoint mutableCopy];
    if (!body)
        body = $mdict();
    [body setValue: _lastSequence.description forKey: @"lastSequence"]; // always save as a string
    
    _savingCheckpoint = YES;
    NSString* checkpointID = self.remoteCheckpointDocID;
    [self sendAsyncRequest: @"PUT"
                      path: [@"_local/" stringByAppendingString: checkpointID]
                      body: body
              onCompletion: ^(id response, NSError* error) {
                  _savingCheckpoint = NO;
                  if (error) {
                      Warn(@"%@: Unable to save remote checkpoint: %@", self, error);
                      // TODO: If error is 401 or 403, and this is a pull, remember that remote is read-only and don't attempt to read its checkpoint next time.
                  } else if (_db) {
                      id rev = response[@"rev"];
                      if (rev)
                          body[@"_rev"] = rev;
                      self.remoteCheckpoint = body;
                      [_db setLastSequence: _lastSequence withCheckpointID: checkpointID];
                  }
                  if (_db && _overdueForSave)
                      [self saveLastSequence];      // start a save that was waiting on me
              }
     ];
}


@end
