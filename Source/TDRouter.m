//
//  TDRouter.m
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

#import "TDRouter.h"
#import "TDDatabase.h"
#import "TDView.h"
#import "TDBody.h"
#import "TDRevision.h"
#import "TDServer.h"
#import "TDReplicator.h"
#import <objc/message.h>


NSString* const kTDVersionString =  @"0.2";


@interface TDRouter ()
- (TDStatus) update: (TDDatabase*)db docID: (NSString*)docID json: (NSData*)json
           deleting: (BOOL)deleting;
@end


@implementation TDRouter

- (id) initWithServer: (TDServer*)server request: (NSURLRequest*)request {
    NSParameterAssert(server);
    NSParameterAssert(request);
    self = [super init];
    if (self) {
        _server = [server retain];
        _request = [request retain];
        _response = [[TDResponse alloc] init];
    }
    return self;
}

- (void)dealloc {
    [self stop];
    [_server release];
    [_request release];
    [_response release];
    [_queries release];
    [_path release];
    [_onResponseReady release];
    [_onDataAvailable release];
    [_onFinished release];
    [super dealloc];
}


@synthesize onResponseReady=_onResponseReady, onDataAvailable=_onDataAvailable,
            onFinished=_onFinished, response=_response;


- (NSDictionary*) queries {
    if (!_queries) {
        NSString* queryString = _request.URL.query;
        if (queryString.length > 0) {
            NSMutableDictionary* queries = $mdict();
            for (NSString* component in [queryString componentsSeparatedByString: @"&"]) {
                NSRange equals = [component rangeOfString: @"="];
                if (equals.length == 0)
                    equals.location = component.length;
                NSString* key = [component substringToIndex: equals.location];
                NSString* value = [component substringFromIndex: NSMaxRange(equals)];
                [queries setObject: value forKey: key];
            }
            _queries = [queries copy];
        }
    }
    return _queries;
}


- (NSString*) query: (NSString*)param {
    return [[self.queries objectForKey: param]
                    stringByReplacingPercentEscapesUsingEncoding: NSUTF8StringEncoding];
}

- (BOOL) boolQuery: (NSString*)param {
    NSString* value = [self query: param];
    return value && !$equal(value, @"false") && !$equal(value, @"0");
}

- (int) intQuery: (NSString*)param defaultValue: (int)defaultValue {
    NSString* value = [self query: param];
    return value ? value.intValue : defaultValue;
}

- (id) jsonQuery: (NSString*)param error: (NSError**)outError {
    *outError = nil;
    NSString* value = [self query: param];
    if (!value)
        return nil;
    id result = [NSJSONSerialization
                            JSONObjectWithData: [value dataUsingEncoding: NSUTF8StringEncoding]
                                       options: NSJSONReadingAllowFragments error: outError];
    if (!result)
        Warn(@"TDRouter: invalid JSON in query param ?%@=%@", param, value);
    return result;
}


- (TDContentOptions) contentOptions {
    TDContentOptions options = 0;
    if ([self boolQuery: @"attachments"])
        options |= kTDIncludeAttachments;
    if ([self boolQuery: @"local_seq"])
        options |= kTDIncludeLocalSeq;
    if ([self boolQuery: @"conflicts"])
        options |= kTDIncludeConflicts;
    if ([self boolQuery: @"revs_info"])
        options |= kTDIncludeRevsInfo;
    return options;
}


- (BOOL) getQueryOptions: (TDQueryOptions*)options {
    // http://wiki.apache.org/couchdb/HTTP_view_API#Querying_Options
    *options = kDefaultTDQueryOptions;
    options->skip = [self intQuery: @"skip" defaultValue: options->skip];
    options->limit = [self intQuery: @"limit" defaultValue: options->limit];
    options->groupLevel = [self intQuery: @"group_level" defaultValue: options->groupLevel];
    options->descending = [self boolQuery: @"descending"];
    options->includeDocs = [self boolQuery: @"include_docs"];
    options->updateSeq = [self boolQuery: @"update_seq"];
    if ([self query: @"inclusive_end"])
        options->inclusiveEnd = [self boolQuery: @"inclusive_end"];
    options->reduce = [self boolQuery: @"reduce"];
    options->group = [self boolQuery: @"group"];
    options->content = [self contentOptions];
    NSError* error = nil;
    options->startKey = [self jsonQuery: @"startkey" error: &error];
    if (error)
        return NO;
    if (!error)
        options->endKey = [self jsonQuery: @"endkey" error: &error];
    return !error;
}


- (TDStatus) openDB {
    if (!_db.exists)
        return 404;
    if (![_db open])
        return 500;
    return 200;
}


static NSArray* splitPath( NSURL* url ) {
    // Unfortunately can't just call url.path because that converts %2F to a '/'.
    NSString* pathString = NSMakeCollectable(CFURLCopyPath((CFURLRef)url));
    NSMutableArray* path = $marray();
    for (NSString* comp in [pathString componentsSeparatedByString: @"/"]) {
        if ([comp length] > 0) {
            comp = [comp stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
            if (!comp)
                return nil;     // bad URL
            [path addObject: comp];
        }
    }
    [pathString release];
    return path;
}


- (void) sendResponse {
    if (!_responseSent) {
        _responseSent = YES;
        if (_onResponseReady)
            _onResponseReady(_response);
    }
}


- (void) start {
    // Refer to: http://wiki.apache.org/couchdb/Complete_HTTP_API_Reference
    
    // We're going to map the request into a selector based on the method and path.
    // Accumulate the selector into the string 'message':
    NSString* method = _request.HTTPMethod;
    if ($equal(method, @"HEAD"))
        method = @"GET";
    NSMutableString* message = [NSMutableString stringWithFormat: @"do_%@", method];
    
    // First interpret the components of the request:
    _path = [splitPath(_request.URL) mutableCopy];
    if (!_path) {
        _response.status = 400;
        return;
    }
        
    NSUInteger pathLen = _path.count;
    if (pathLen > 0) {
        NSString* dbName = [_path objectAtIndex: 0];
        if ([dbName hasPrefix: @"_"]) {
            [message appendString: dbName]; // special root path, like /_all_dbs
        } else {
            _db = [[_server databaseNamed: dbName] retain];
            if (!_db) {
                _response.status = 400;
                return;
            }
            [message appendString: @":"];
        }
    } else {
        [message appendString: @"Root"];
    }
    
    NSString* docID = nil;
    if (_db && pathLen > 1) {
        // Make sure database exists, then interpret doc name:
        TDStatus status = [self openDB];
        if (status >= 300) {
            _response.status = status;
            return;
        }
        NSString* name = [_path objectAtIndex: 1];
        if (![TDDatabase isValidDocumentID: name]) {
            _response.status = 400;
            return;
        } else if (![name hasPrefix: @"_"]) {
            // Regular document
            docID = name;
        } else if ([name isEqualToString: @"_design"]) {
            // "_design/____" is a document name
            if (pathLen <= 2) {
                _response.status = 404;
                return;
            }
            docID = [@"_design/" stringByAppendingString: [_path objectAtIndex: 2]];
            [_path replaceObjectAtIndex: 1 withObject: docID];
            [_path removeObjectAtIndex: 2];
            --pathLen;
        } else {
            // Special document name like "_all_docs":
            [message insertString: name atIndex: message.length-1]; // add to 1st component of msg
            if (pathLen > 2)
                docID = [[_path subarrayWithRange: NSMakeRange(2, _path.count-2)]
                         componentsJoinedByString: @"/"];
        }

        if (docID)
            [message appendString: @"docID:"];
    }
    
    NSString* attachmentName = nil;
    if (docID && pathLen > 2) {
        // Interpret attachment name:
        attachmentName = [_path objectAtIndex: 2];
        if ([attachmentName hasPrefix: @"_"] && [docID hasPrefix: @"_design/"]) {
            // Design-doc attribute like _info or _view
            [message replaceOccurrencesOfString: @":docID:" withString: @":designDocID:"
                                        options:0 range: NSMakeRange(0, message.length)];
            docID = [docID substringFromIndex: 8];  // strip the "_design/" prefix
            [message appendString: [attachmentName substringFromIndex: 1]];
            [message appendString: @":"];
            attachmentName = pathLen > 3 ? [_path objectAtIndex: 3] : nil;
        } else {
            [message appendString: @"attachment:"];
        }
    }
    
    // Send myself a message based on the components:
    SEL sel = NSSelectorFromString(message);
    if (!sel || ![self respondsToSelector: sel]) {
        Log(@"TDRouter: unknown request type: %@ %@ (mapped to %@)",
             _request.HTTPMethod, _request.URL.path, message);
        sel = @selector(do_UNKNOWN);
    }
    TDStatus status = (TDStatus) objc_msgSend(self, sel, _db, docID, attachmentName);

    // Configure response headers:
    if (status < 300 && !_response.body && ![_response.headers objectForKey: @"Content-Type"]) {
        _response.body = [TDBody bodyWithJSON: [@"{\"ok\":true}" dataUsingEncoding: NSUTF8StringEncoding]];
    }
    if (_response.body.isValidJSON)
        [_response setValue: @"application/json" ofHeader: @"Content-Type"];

    [_response.headers setObject: $sprintf(@"TouchDB %@", kTDVersionString)
                          forKey: @"Server"];

    // If response is ready (nonzero status), tell my client about it:
    if (status > 0) {
        _response.status = status;
        [self sendResponse];
        if (_onDataAvailable && _response.body) {
            _onDataAvailable(_response.body.asJSON);
        }
        if (_onFinished && !_waiting)
            _onFinished();
    }
}


- (void) stop {
    self.onResponseReady = nil;
    self.onDataAvailable = nil;
    self.onFinished = nil;
    [[NSNotificationCenter defaultCenter] removeObserver: self];
}


- (TDStatus) do_UNKNOWN {
    return 400;
}


#pragma mark - SERVER REQUESTS:


- (TDStatus) do_GETRoot {
    NSDictionary* info = $dict({@"TouchDB", @"Welcome"},
                               {@"couchdb", @"Welcome"},        // for compatibility
                               {@"version", kTDVersionString});
    _response.body = [TDBody bodyWithProperties: info];
    return 200;
}

- (TDStatus) do_GET_all_dbs {
    NSArray* dbs = _server.allDatabaseNames ?: $array();
    _response.body = [[[TDBody alloc] initWithArray: dbs] autorelease];
    return 200;
}

- (TDStatus) do_POST_replicate {
    // Extract the parameters from the JSON request body:
    // http://wiki.apache.org/couchdb/Replication
    id body = [NSJSONSerialization JSONObjectWithData: _request.HTTPBody options: 0 error: nil];
    if (![body isKindOfClass: [NSDictionary class]])
        return 400;
    NSString* source = $castIf(NSString, [body objectForKey: @"source"]);
    NSString* target = $castIf(NSString, [body objectForKey: @"target"]);
    BOOL createTarget = [$castIf(NSNumber, [body objectForKey: @"create_target"]) boolValue];
    BOOL continuous = [$castIf(NSNumber, [body objectForKey: @"continuous"]) boolValue];
    BOOL cancel = [$castIf(NSNumber, [body objectForKey: @"cancel"]) boolValue];
    
    // Map the 'source' and 'target' JSON params to a local database and remote URL:
    if (!source || !target)
        return 400;
    BOOL push = NO;
    TDDatabase* db = [_server existingDatabaseNamed: source];
    NSString* remoteStr;
    if (db) {
        remoteStr = target;
        push = YES;
    } else {
        remoteStr = source;
        if (createTarget && !cancel) {
            db = [_server databaseNamed: target];
            if (![db open])
                return 500;
        } else {
            db = [_server existingDatabaseNamed: target];
        }
        if (!db)
            return 404;
    }
    NSURL* remote = [NSURL URLWithString: remoteStr];
    if (!remote || ![remote.scheme hasPrefix: @"http"])
        return 400;
    
    if (!cancel) {
        // Start replication:
        TDReplicator* repl = [db replicateWithRemoteURL: remote push: push continuous: continuous];
        if (!repl)
            return 500;
        _response.bodyObject = $dict({@"session_id", repl.sessionID});
    } else {
        // Cancel replication:
        TDReplicator* repl = [db activeReplicatorWithRemoteURL: remote push: push];
        if (!repl)
            return 404;
        [repl stop];
    }
    return 200;
}


- (TDStatus) do_GET_uuids {
    int count = MIN(1000, [self intQuery: @"count" defaultValue: 1]);
    NSMutableArray* uuids = [NSMutableArray arrayWithCapacity: count];
    for (int i=0; i<count; i++)
        [uuids addObject: [TDDatabase generateDocumentID]];
    _response.bodyObject = $dict({@"uuids", uuids});
    return 200;
}


- (TDStatus) do_GET_active_tasks {
    // http://wiki.apache.org/couchdb/HttpGetActiveTasks
    NSMutableArray* activity = $marray();
    for (TDDatabase* db in _server.allOpenDatabases) {
        for (TDReplicator* repl in db.activeReplicators) {
            NSString* source = repl.remote.absoluteString;
            NSString* target = db.name;
            if (repl.isPush) {
                NSString* temp = source;
                source = target;
                target = temp;
            }
            NSUInteger processed = repl.changesProcessed;
            NSUInteger total = repl.changesTotal;
            NSString* status = $sprintf(@"Processed %u / %u changes",
                                        (unsigned)processed, (unsigned)total);
            long progress = (total > 0) ? lroundf(100*(processed / (float)total)) : 0;
            [activity addObject: $dict({@"type", @"Replication"},
                                       {@"task", repl.sessionID},
                                       {@"source", source},
                                       {@"target", target},
                                       {@"status", status},
                                       {@"progress", $object(progress)})];
        }
    }
    _response.body = [[[TDBody alloc] initWithArray: activity] autorelease];
    return 200;
}


#pragma mark - DATABASE REQUESTS:


- (TDStatus) do_GET: (TDDatabase*)db {
    // http://wiki.apache.org/couchdb/HTTP_database_API#Database_Information
    TDStatus status = [self openDB];
    if (status >= 300)
        return status;
    NSUInteger num_docs = db.documentCount;
    SequenceNumber update_seq = db.lastSequence;
    if (num_docs == NSNotFound || update_seq == NSNotFound)
        return 500;
    _response.bodyObject = $dict({@"db_name", db.name},
                                 {@"doc_count", $object(num_docs)},
                                 {@"update_seq", $object(update_seq)});
    return 200;
}


- (TDStatus) do_PUT: (TDDatabase*)db {
    if (db.exists)
        return 412;
    if (![db open])
        return 500;
    [_response setValue: _request.URL.absoluteString ofHeader: @"Location"];
    return 201;
}


- (TDStatus) do_DELETE: (TDDatabase*)db {
    if ([self query: @"rev"])
        return 400;  // CouchDB checks for this; probably meant to be a document deletion
    return [_server deleteDatabaseNamed: db.name] ? 200 : 404;
}


- (TDStatus) do_POST: (TDDatabase*)db {
    TDStatus status = [self openDB];
    if (status >= 300)
        return status;
    return [self update: db docID: nil json: _request.HTTPBody deleting: NO];
}


- (TDStatus) do_GET_all_docs: (TDDatabase*)db {
    TDQueryOptions options;
    if (![self getQueryOptions: &options])
        return 400;
    NSDictionary* result = [db getAllDocs: &options];
    if (!result)
        return 500;
    _response.bodyObject = result;
    return 200;
}


- (TDStatus) do_POST_all_docs: (TDDatabase*)db {
    // http://wiki.apache.org/couchdb/HTTP_Bulk_Document_API
    TDQueryOptions options;
    if (![self getQueryOptions: &options])
        return 400;
    
    NSDictionary* body = [NSJSONSerialization JSONObjectWithData: _request.HTTPBody
                                                         options: 0 error: nil];
    if (![body isKindOfClass: [NSDictionary class]])
        return 400;
    NSArray* docIDs = [body objectForKey: @"keys"];
    if (![docIDs isKindOfClass: [NSArray class]])
        return 400;
    
    NSDictionary* result = [db getDocsWithIDs: docIDs options: &options];
    if (!result)
        return 500;
    _response.bodyObject = result;
    return 200;
}


- (TDStatus) do_POST_compact: (TDDatabase*)db {
    return [db compact];
}

- (TDStatus) do_POST_ensure_full_commit: (TDDatabase*)db {
    return 200;
}


#pragma mark - CHANGES:


- (NSDictionary*) changeDictForRev: (TDRevision*)rev {
    return $dict({@"seq", $object(rev.sequence)},
                 {@"id",  rev.docID},
                 {@"changes", $marray($dict({@"rev", rev.revID}))},
                 {@"deleted", rev.deleted ? $true : nil},
                 {@"doc", (_changesIncludeDocs ? rev.properties : nil)});
}

- (NSDictionary*) responseBodyForChanges: (NSArray*)changes since: (UInt64)since {
    NSArray* results = [changes my_map: ^(id rev) {return [self changeDictForRev: rev];}];
    if (changes.count > 0)
        since = [[changes lastObject] sequence];
    return $dict({@"results", results}, {@"last_seq", $object(since)});
}


- (NSDictionary*) responseBodyForChangesWithConflicts: (NSArray*)changes since: (UInt64)since {
    // Assumes the changes are grouped by docID so that conflicts will be adjacent.
    NSMutableArray* entries = [NSMutableArray arrayWithCapacity: changes.count];
    NSString* lastDocID = nil;
    NSDictionary* lastEntry = nil;
    for (TDRevision* rev in changes) {
        NSString* docID = rev.docID;
        if ($equal(docID, lastDocID)) {
            [[lastEntry objectForKey: @"changes"] addObject: $dict({@"rev", rev.revID})];
        } else {
            lastEntry = [self changeDictForRev: rev];
            [entries addObject: lastEntry];
            lastDocID = docID;
        }
    }
    // After collecting revisions, sort by sequence:
    [entries sortUsingComparator: ^NSComparisonResult(id e1, id e2) {
        return [[e1 objectForKey: @"seq"] longLongValue] - [[e2 objectForKey: @"seq"] longLongValue];
    }];
    return $dict({@"results", entries}, {@"last_seq", $object(since)});
}


- (void) sendContinuousChange: (TDRevision*)rev {
    NSDictionary* changeDict = [self changeDictForRev: rev];
    NSMutableData* json = [[NSJSONSerialization dataWithJSONObject: changeDict
                                                           options: 0 error: nil] mutableCopy];
    [json appendBytes: @"\n" length: 1];
    _onDataAvailable(json);
    [json release];
}


- (void) dbChanged: (NSNotification*)n {
    TDRevision* rev = [n.userInfo objectForKey: @"rev"];
    
    if (_changesFilter && !_changesFilter(rev))
        return;

    if (_longpoll) {
        Log(@"TDRouter: Sending longpoll response");
        [self sendResponse];
        NSDictionary* body = [self responseBodyForChanges: $array(rev) since: 0];
        _onDataAvailable([NSJSONSerialization dataWithJSONObject: body
                                                         options: 0 error: nil]);
        _onFinished();
        [self stop];
    } else {
        Log(@"TDRouter: Sending continous change chunk");
        [self sendContinuousChange: rev];
    }
}


- (TDStatus) do_GET_changes: (TDDatabase*)db {
    // http://wiki.apache.org/couchdb/HTTP_database_API#Changes
    TDChangesOptions options = kDefaultTDChangesOptions;
    _changesIncludeDocs = [self boolQuery: @"include_docs"];
    options.includeDocs = _changesIncludeDocs;
    options.includeConflicts = $equal([self query: @"style"], @"all_docs");
    options.contentOptions = [self contentOptions];
    options.sortBySequence = !options.includeConflicts;
    options.limit = [self intQuery: @"limit" defaultValue: options.limit];
    int since = [[self query: @"since"] intValue];
    
    NSString* filterName = [self query: @"filter"];
    if (filterName) {
        _changesFilter = [[_db filterNamed: filterName] retain];
        if (!_changesFilter)
            return 404;
    }
    
    TDRevisionList* changes = [db changesSinceSequence: since
                                               options: &options
                                                filter: _changesFilter];
    if (!changes)
        return 500;
    
    NSString* feed = [self query: @"feed"];
    _longpoll = $equal(feed, @"longpoll");
    BOOL continuous = !_longpoll && $equal(feed, @"continuous");
    
    if (continuous || (_longpoll && changes.count==0)) {
        if (continuous) {
            [self sendResponse];
            for (TDRevision* rev in changes) 
                [self sendContinuousChange: rev];
        }
        [[NSNotificationCenter defaultCenter] addObserver: self 
                                                 selector: @selector(dbChanged:)
                                                     name: TDDatabaseChangeNotification
                                                   object: db];
        // Don't close connection; more data to come
        _waiting = YES;
        return 0;
    } else {
        if (options.includeConflicts)
            _response.bodyObject = [self responseBodyForChangesWithConflicts: changes.allRevisions
                                                                       since: since];
        else
            _response.bodyObject = [self responseBodyForChanges: changes.allRevisions since: since];
        return 200;
    }
}


#pragma mark - DOCUMENT REQUESTS:


- (NSString*) setResponseEtag: (TDRevision*)rev {
    NSString* eTag = $sprintf(@"\"%@\"", rev.revID);
    [_response setValue: eTag ofHeader: @"Etag"];
    return eTag;
}


- (TDStatus) do_GET: (TDDatabase*)db docID: (NSString*)docID {
    // http://wiki.apache.org/couchdb/HTTP_Document_API#GET
    TDRevision* rev = [db getDocumentWithID: docID
                                 revisionID: [self query: @"rev"]  // often nil
                                    options: [self contentOptions]];
    if (!rev)
        return 404;
    
    // Check for conditional GET:
    NSString* eTag = [self setResponseEtag: rev];
    if ($equal(eTag, [_request valueForHTTPHeaderField: @"If-None-Match"]))
        return 304;
    
    _response.body = rev.body;
    return 200;
}


- (TDStatus) do_GET: (TDDatabase*)db docID: (NSString*)docID attachment: (NSString*)attachment {
    //OPT: This gets the JSON body too, which is a waste. Could add a 'withBody:' attribute?
    TDRevision* rev = [db getDocumentWithID: docID
                                 revisionID: [self query: @"rev"]  // often nil
                                    options: 0];
    if (!rev)
        return 404;
    
    // Check for conditional GET:
    NSString* eTag = [self setResponseEtag: rev];
    if ($equal(eTag, [_request valueForHTTPHeaderField: @"If-None-Match"]))
        return 304;
    
    NSString* type = nil;
    TDStatus status;
    NSData* contents = [_db getAttachmentForSequence: rev.sequence
                                               named: attachment
                                                type: &type
                                              status: &status];
    if (!contents)
        return status;
    if (type)
        [_response setValue: type ofHeader: @"Content-Type"];
    _response.body = [TDBody bodyWithJSON: contents];   //FIX: This is a lie, it's not JSON
    return 200;
}


- (TDStatus) update: (TDDatabase*)db
              docID: (NSString*)docID
               json: (NSData*)json
           deleting: (BOOL)deleting
{
    BOOL posting = (docID == nil);
    TDBody* body = json ? [TDBody bodyWithJSON: json] : nil;
    
    NSString* prevRevID;
    if (!deleting) {
        deleting = $castIf(NSNumber, [body propertyForKey: @"_deleted"]).boolValue;
        if (!docID) {
            // POST's doc ID may come from the _id field of the JSON body, else generate a random one.
            docID = [body propertyForKey: @"_id"];
            if (!docID) {
                if (deleting)
                    return 400;
                docID = [TDDatabase generateDocumentID];
            }
        }
        // PUT's revision ID comes from the JSON body.
        prevRevID = [body propertyForKey: @"_rev"];
    } else {
        // DELETE's revision ID can come either from the ?rev= query param or an If-Match header.
        prevRevID = [self query: @"rev"];
        if (!prevRevID) {
            NSString* ifMatch = [_request valueForHTTPHeaderField: @"If-Match"];
            if (ifMatch) {
                // Value of If-Match is an ETag, so have to trim the quotes around it:
                if (ifMatch.length > 2 && [ifMatch hasPrefix: @"\""] && [ifMatch hasSuffix: @"\""])
                    prevRevID = [ifMatch substringWithRange: NSMakeRange(1, ifMatch.length-2)];
                else
                    return 400;
            }
        }
    }
    
    TDRevision* rev = [[[TDRevision alloc] initWithDocID: docID revID: nil deleted: deleting]
                            autorelease];
    if (!rev)
        return 400;
    rev.body = body;
    
    TDStatus status;
    rev = [db putRevision: rev prevRevisionID: prevRevID status: &status];
    if (status < 300) {
        [self setResponseEtag: rev];
        if (!deleting) {
            NSURL* url = _request.URL;
            if (posting)
                url = [url URLByAppendingPathComponent: docID];
            [_response.headers setObject: url.absoluteString forKey: @"Location"];
        }
        _response.bodyObject = $dict({@"ok", $true},
                                     {@"id", rev.docID},
                                     {@"rev", rev.revID});
    }
    return status;
}


- (TDStatus) do_PUT: (TDDatabase*)db docID: (NSString*)docID {
    NSData* json = _request.HTTPBody;
    if (!json)
        return 400;
    
    if (![self query: @"new_edits"] || [self boolQuery: @"new_edits"]) {
        // Regular PUT:
        return [self update: db docID: docID json: json deleting: NO];
    } else {
        // PUT with new_edits=false -- forcible insertion of existing revision:
        TDBody* body =  [TDBody bodyWithJSON: json];
        TDRevision* rev = [[[TDRevision alloc] initWithBody: body] autorelease];
        if (!rev || !$equal(rev.docID, docID) || !rev.revID)
            return 400;
        NSArray* history = [TDDatabase parseCouchDBRevisionHistory: body.properties];
        if (!history)
            history = $array(rev.revID);
        return [_db forceInsert: rev revisionHistory: history source: nil];
    }
}


- (TDStatus) do_DELETE: (TDDatabase*)db docID: (NSString*)docID {
    return [self update: db docID: docID json: nil deleting: YES];
}


#pragma mark - VIEW QUERIES:


- (TDStatus) do_GET: (TDDatabase*)db designDocID: (NSString*)designDoc view: (NSString*)viewName {
    viewName = $sprintf(@"%@/%@", designDoc, viewName);
    TDView* view = [db existingViewNamed: viewName];
    if (!view)
        return 404;
    
    TDQueryOptions options;
    if (![self getQueryOptions: &options])
        return 400;

    TDStatus status;
    NSArray* rows = [view queryWithOptions: &options status: &status];
    if (!rows)
        return status;
    id updateSeq = options.updateSeq ? $object(view.lastSequenceIndexed) : nil;
    _response.bodyObject = $dict({@"rows", rows},
                                 {@"total_rows", $object(rows.count)},
                                 {@"offset", $object(options.skip)},
                                 {@"update_seq", updateSeq});
    return 200;
}


- (TDStatus) do_POST_temp_view: (TDDatabase*)db {
    if (![[_request valueForHTTPHeaderField: @"Content-Type"] hasPrefix: @"application/json"])
        return 415;
    TDBody* requestBody = [TDBody bodyWithJSON: _request.HTTPBody];
    NSDictionary* props = requestBody.properties;
    if (!props)
        return 400;
    
    TDQueryOptions options;
    if (![self getQueryOptions: &options])
        return 400;
    
    TDView* view = [_db viewNamed: @"@@TEMP@@"];
    if (!view)
        return 500;
    @try {
        NSString* language = [props objectForKey: @"language"] ?: @"javascript";
        NSString* mapSource = [props objectForKey: @"map"];
        TDMapBlock mapBlock = [[TDView compiler] compileMapFunction: mapSource language: language];
        if (!mapBlock) {
            Warn(@"Unknown map function source: %@", mapSource);
            return 500;
        }
        NSString* reduceSource = [props objectForKey: @"reduce"];
        TDReduceBlock reduceBlock = NULL;
        if (reduceSource) {
            reduceBlock =[[TDView compiler] compileReduceFunction: reduceSource language: language];
            if (!reduceBlock) {
                Warn(@"Unknown reduce function source: %@", reduceSource);
                return 500;
            }
        }
        
        [view setMapBlock: mapBlock reduceBlock: reduceBlock version: @"1"];
        if (reduceBlock)
            options.reduce = YES;
        
        TDStatus status;
        NSArray* rows = [view queryWithOptions: &options status: &status];
        if (!rows)
            return status;
        id updateSeq = options.updateSeq ? $object(view.lastSequenceIndexed) : nil;
        _response.bodyObject = $dict({@"rows", rows},
                                     {@"total_rows", $object(rows.count)},
                                     {@"offset", $object(options.skip)},
                                     {@"update_seq", updateSeq});
        return 200;
    } @finally {
        [view deleteView];
    }
}


@end




#pragma mark - TDRESPONSE

@implementation TDResponse

- (id) init
{
    self = [super init];
    if (self) {
        _status = 200;
        _headers = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc {
    [_headers release];
    [_body release];
    [super dealloc];
}

@synthesize status=_status, headers=_headers, body=_body;

- (void) setValue: (NSString*)value ofHeader: (NSString*)header {
    [_headers setValue: value forKey: header];
}

- (id) bodyObject {
    return self.body.asObject;
}

- (void) setBodyObject:(id)bodyObject {
    self.body = bodyObject ? [TDBody bodyWithProperties: bodyObject] : nil;
}

@end
