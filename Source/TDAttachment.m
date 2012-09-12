//
//  TDAttachment.m
//  TouchDB
//
//  Created by Jens Alfke on 4/3/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//

#import "TDAttachment.h"
#import "Test.h"

@implementation TDAttachment


@synthesize name=_name, contentType=_contentType;


- (id) initWithName: (NSString*)name contentType: (NSString*)contentType {
    Assert(name);
    self = [super init];
    if (self) {
        _name = [name copy];
        _contentType = [contentType copy];
    }
    return self;
}


- (void)dealloc
{
    [_name release];
    [_contentType release];
    [super dealloc];
}


- (bool) isValid {
    if (encoding) {
        if (encodedLength == 0 && length > 0)
            return false;
    } else if (encodedLength > 0) {
        return false;
    }
    if (revpos == 0)
        return false;
#if DEBUG
    size_t i;
    for (i=0; i<sizeof(TDBlobKey); i++)
        if (blobKey.bytes[i])
            return true;
    return false;
#else
    return true;
#endif
}


@end
