//
//  TDPersonaAuthorizer.h
//  TouchDB
//
//  Created by Jens Alfke on 1/9/13.
//
//

#import "TDAuthorizer.h"

/** Authorizer for the Persona decentralized-identity system. See http://persona.org */
@interface TDPersonaAuthorizer: NSObject <TDAuthorizer>

+ (NSURL*) originForSite: (NSURL*)url;

+ (NSString*) registerAssertion: (NSString*)assertion;

- (id) initWithEmailAddress: (NSString*)emailAddress;

@property (readonly) NSString* emailAddress;

- (NSString*) assertionForSite: (NSURL*)site;

@end
