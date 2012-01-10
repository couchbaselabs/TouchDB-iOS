//
//  TDRouter+Handlers.m
//  TouchDB
//
//  Created by Jens Alfke on 1/5/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//

#import "TDRouter.h"
#import "TDDatabase.h"
#import "TDView.h"
#import "TDBody.h"
#import "TDRevision.h"
#import "TDServer.h"
#import "TDReplicator.h"


@interface TDRouter ()
- (TDStatus) update: (TDDatabase*)db
              docID: (NSString*)docID
               body: (TDBody*)body
           deleting: (BOOL)deleting
      allowConflict: (BOOL)allowConflict
         createdRev: (TDRevision**)outRev;
- (TDStatus) update: (TDDatabase*)db
              docID: (NSString*)docID
               json: (NSData*)json
           deleting: (BOOL)deleting;
@end


@implementation TDRouter (Handlers)


- (void) setResponseLocation: (NSURL*)url {
    // Strip anything after the URL's path (i.e. the query string)
    CFURLRef cfURL = (CFURLRef)url;
    CFRange range = CFURLGetByteRangeForComponent(cfURL, kCFURLComponentResourceSpecifier, NULL);
    if (range.length == 0) {
        [_response setValue: url.absoluteString ofHeader: @"Location"];
    } else {
        CFIndex size = CFURLGetBytes(cfURL, NULL, 0);
        if (size > 8000)
            return;
        UInt8 bytes[size];
        CFURLGetBytes(cfURL, bytes, size);
        cfURL = CFURLCreateWithBytes(NULL, bytes, range.location - 1, kCFStringEncodingUTF8, NULL);
        [_response setValue: (id)CFURLGetString(cfURL) ofHeader: @"Location"];
        CFRelease(cfURL);
    }
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
    id body = self.bodyAsDictionary;
    if (!body)
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
                                 {@"update_seq", $object(update_seq)},
                                 {@"disk_size", $object(db.totalDataSize)});
    return 200;
}


- (TDStatus) do_PUT: (TDDatabase*)db {
    if (db.exists)
        return 412;
    if (![db open])
        return 500;
    [self setResponseLocation: _request.URL];
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
    
    NSDictionary* body = self.bodyAsDictionary;
    if (!body)
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


- (TDStatus) do_POST_bulk_docs: (TDDatabase*)db {
    // http://wiki.apache.org/couchdb/HTTP_Bulk_Document_API
    NSDictionary* body = self.bodyAsDictionary;
    NSArray* docs = $castIf(NSArray, [body objectForKey: @"docs"]);
    Log(@"_bulk_docs: Got %@", body); //TEMP
    if (!docs)
        return 400;
    id allObj = [body objectForKey: @"all_or_nothing"];
    BOOL allOrNothing = (allObj && allObj != $false);
    BOOL noNewEdits = ([body objectForKey: @"new_edits"] == $false);

    BOOL ok = NO;
    NSMutableArray* results = [NSMutableArray arrayWithCapacity: docs.count];
    [_db beginTransaction];
    @try{
        for (NSDictionary* doc in docs) {
            @autoreleasepool {
                NSString* docID = [doc objectForKey: @"_id"];
                TDRevision* rev;
                TDStatus status;
                TDBody* docBody = [TDBody bodyWithProperties: doc];
                if (noNewEdits) {
                    rev = [[[TDRevision alloc] initWithBody: docBody] autorelease];
                    NSArray* history = [TDDatabase parseCouchDBRevisionHistory: doc];
                    status = rev ? [db forceInsert: rev revisionHistory: history source: nil] : 400;
                } else {
                    status = [self update: db
                                    docID: docID
                                     body: docBody
                                 deleting: NO
                            allowConflict: allOrNothing
                               createdRev: &rev];
                }
                NSDictionary* result = nil;
                if (status < 300) {
                    Assert(rev.revID);
                    if (!noNewEdits)
                        result = $dict({@"id", rev.docID}, {@"rev", rev.revID}, {@"ok", $true});
                } else if (allOrNothing) {
                    return status;  // all_or_nothing backs out if there's any error
                } else if (status == 403) {
                    result = $dict({@"id", docID}, {@"error", @"validation failed"});
                } else if (status == 409) {
                    result = $dict({@"id", docID}, {@"error", @"conflict"});
                } else {
                    return status;  // abort the whole thing if something goes badly wrong
                }
                if (result)
                    [results addObject: result];
            }
        }
        ok = YES;
    } @finally {
        [_db endTransaction: ok];
    }
    
    Log(@"_bulk_docs: Returning %@", results); //TEMP
    _response.bodyObject = results;
    return 201;
}


- (TDStatus) do_POST_compact: (TDDatabase*)db {
    TDStatus status = [db compact];
    return status<300 ? 202 : status;       // CouchDB returns 202 'cause it's an async operation
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


- (NSString*) revIDFromIfMatchHeader {
    NSString* ifMatch = [_request valueForHTTPHeaderField: @"If-Match"];
    if (!ifMatch)
        return nil;
    // Value of If-Match is an ETag, so have to trim the quotes around it:
    if (ifMatch.length > 2 && [ifMatch hasPrefix: @"\""] && [ifMatch hasSuffix: @"\""])
        return [ifMatch substringWithRange: NSMakeRange(1, ifMatch.length-2)];
    else
        return nil;
}


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
    //OPT: This gets the JSON body too, which is a waste. Could add a kNoBody option?
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
               body: (TDBody*)body
           deleting: (BOOL)deleting
      allowConflict: (BOOL)allowConflict
         createdRev: (TDRevision**)outRev
{
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
        // DELETE's revision ID comes from the ?rev= query param
        prevRevID = [self query: @"rev"];
    }

    // A backup source of revision ID is an If-Match header:
    if (!prevRevID)
        prevRevID = [self revIDFromIfMatchHeader];

    TDRevision* rev = [[[TDRevision alloc] initWithDocID: docID revID: nil deleted: deleting]
                            autorelease];
    if (!rev)
        return 400;
    rev.body = body;
    
    TDStatus status;
    *outRev = [db putRevision: rev prevRevisionID: prevRevID
                allowConflict: allowConflict
                       status: &status];
    return status;
}


- (TDStatus) update: (TDDatabase*)db
              docID: (NSString*)docID
               json: (NSData*)json
           deleting: (BOOL)deleting
{
    TDBody* body = json ? [TDBody bodyWithJSON: json] : nil;
    TDRevision* rev;
    TDStatus status = [self update: db docID: docID body: body
                          deleting: deleting
                     allowConflict: NO
                        createdRev: &rev];
    if (status < 300) {
        [self setResponseEtag: rev];
        if (!deleting) {
            NSURL* url = _request.URL;
            if (!docID)
                url = [url URLByAppendingPathComponent: rev.docID];
            [self setResponseLocation: url];
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
        return [_db forceInsert: rev revisionHistory: history source: nil];
    }
}


- (TDStatus) do_DELETE: (TDDatabase*)db docID: (NSString*)docID {
    return [self update: db docID: docID json: nil deleting: YES];
}


- (TDStatus) updateAttachment: (NSString*)attachment docID: (NSString*)docID body: (NSData*)body {
    TDStatus status;
    TDRevision* rev = [_db updateAttachment: attachment 
                                       body: body
                                       type: [_request valueForHTTPHeaderField: @"Content-Type"]
                                    ofDocID: docID
                                      revID: ([self query: @"rev"] ?: [self revIDFromIfMatchHeader])
                                     status: &status];
    if (status < 300) {
        _response.bodyObject = $dict({@"ok", $true}, {@"id", rev.docID}, {@"rev", rev.revID});
        [self setResponseEtag: rev];
        if (body)
            [self setResponseLocation: _request.URL];
    }
    return status;
}


- (TDStatus) do_PUT: (TDDatabase*)db docID: (NSString*)docID attachment: (NSString*)attachment {
    return [self updateAttachment: attachment
                            docID: docID
                             body: (_request.HTTPBody ?: [NSData data])];
}


- (TDStatus) do_DELETE: (TDDatabase*)db docID: (NSString*)docID attachment: (NSString*)attachment {
    return [self updateAttachment: attachment
                            docID: docID
                             body: nil];
}


#pragma mark - VIEW QUERIES:


- (TDView*) compileView: (NSString*)viewName fromProperties: (NSDictionary*)viewProps {
    NSString* language = [viewProps objectForKey: @"language"] ?: @"javascript";
    NSString* mapSource = [viewProps objectForKey: @"map"];
    if (!mapSource)
        return nil;
    TDMapBlock mapBlock = [[TDView compiler] compileMapFunction: mapSource language: language];
    if (!mapBlock) {
        Warn(@"View %@ has unknown map function: %@", viewName, mapSource);
        return nil;
    }
    NSString* reduceSource = [viewProps objectForKey: @"reduce"];
    TDReduceBlock reduceBlock = NULL;
    if (reduceSource) {
        reduceBlock =[[TDView compiler] compileReduceFunction: reduceSource language: language];
        if (!reduceBlock) {
            Warn(@"View %@ has unknown reduce function: %@", viewName, reduceSource);
            return nil;
        }
    }
    
    TDView* view = [_db viewNamed: viewName];
    [view setMapBlock: mapBlock reduceBlock: reduceBlock version: @"1"];
    
    NSDictionary* options = $castIf(NSDictionary, [viewProps objectForKey: @"options"]);
    if ($equal([options objectForKey: @"collation"], @"raw"))
        view.collation = kTDViewCollationRaw;
    return view;
}


- (TDStatus) queryDesignDoc: (NSString*)designDoc view: (NSString*)viewName keys: (NSArray*)keys {
    NSString* tdViewName = $sprintf(@"%@/%@", designDoc, viewName);
    TDView* view = [_db existingViewNamed: tdViewName];
    if (!view || !view.mapBlock) {
        // No TouchDB view is defined, or it hasn't had a map block assigned;
        // see if there's a CouchDB view definition we can compile:
        TDRevision* rev = [_db getDocumentWithID: [@"_design/" stringByAppendingString: designDoc]
                                      revisionID: nil options: 0];
        if (!rev)
            return 404;
        NSDictionary* views = $castIf(NSDictionary, [rev.properties objectForKey: @"views"]);
        NSDictionary* viewProps = $castIf(NSDictionary, [views objectForKey: viewName]);
        if (!viewProps)
            return 404;
        // If there is a CouchDB view, see if it can be compiled from source:
        view = [self compileView: tdViewName fromProperties: viewProps];
        if (!view)
            return 500;
    }
    
    TDQueryOptions options;
    if (![self getQueryOptions: &options])
        return 400;
    if (keys)
        options.keys = keys;

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


- (TDStatus) do_GET: (TDDatabase*)db designDocID: (NSString*)designDoc view: (NSString*)viewName {
    return [self queryDesignDoc: designDoc view: viewName keys: nil];
}


- (TDStatus) do_POST: (TDDatabase*)db designDocID: (NSString*)designDoc view: (NSString*)viewName {
    NSArray* keys = $castIf(NSArray, [self.bodyAsDictionary objectForKey: @"keys"]);
    if (!keys)
        return 400;
    return [self queryDesignDoc: designDoc view: viewName keys: keys];
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
    
    TDView* view = [self compileView: @"@@TEMP@@" fromProperties: props];
    if (!view)
        return 500;
    @try {
        if (view.reduceBlock)
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
