//
//  P2P_Tests.m
//  CouchbaseLite
//
//  Created by Jens Alfke on 7/6/15.
//  Copyright © 2015 Couchbase, Inc. All rights reserved.
//

#import "CBLTestCase.h"
#import "CBLSyncListener.h"
#import "CBLHTTPListener.h"
#import "CBLManager+Internal.h"


#define kPort 59999
#define kListenerDBName @"listy"
#define kNDocuments 100
#define kMinAttachmentLength   4000
#define kMaxAttachmentLength 100000

#define USE_AUTH 1


@interface P2P_HTTP_Tests : CBLTestCaseWithDB
@end


@implementation P2P_HTTP_Tests
{
    @protected
    CBLListener* listener;
    CBLDatabase* listenerDB;
    NSURL* listenerDBURL;
}


- (Class) listenerClass {
    return [CBLHTTPListener class];
}

- (NSString*) replicatorClassName {
    return @"CBLRestReplicator";
}


- (void) setUp {
    [super setUp];

    dbmgr.replicatorClassName = self.replicatorClassName;

    listenerDB = [dbmgr databaseNamed: kListenerDBName error: NULL];
    listenerDBURL = [NSURL URLWithString: $sprintf(@"http://localhost:%d/%@", kPort, kListenerDBName)];

    listener = [[[self listenerClass] alloc] initWithManager: dbmgr port: kPort];
#if USE_AUTH
    listener.requiresAuth = YES;
    listener.passwords = @{@"bob": @"slack"};
#endif

    // Wait for listener to start:
    [self keyValueObservingExpectationForObject: listener keyPath: @"port" expectedValue: @(kPort)];
    [listener start: NULL];
    [self waitForExpectationsWithTimeout: 5.0 handler: nil];
}


- (void) tearDown {
    [listener stop];
    [super tearDown];
}


- (void) testPush {
    [self createDocsIn: db withAttachments: NO];
    Log(@"Pushing...");
    CBLReplication* repl = [db createPushReplication: listenerDBURL];
    [self runReplication: repl expectedChangesCount: kNDocuments];
    [self verifyDocsIn: listenerDB withAttachments: NO];
}

- (void) testPull {
    [self createDocsIn: listenerDB withAttachments: NO];
    Log(@"Pulling...");
    CBLReplication* repl = [db createPullReplication: listenerDBURL];
    [self runReplication: repl expectedChangesCount: kNDocuments];
    [self verifyDocsIn: db withAttachments: NO];
}

- (void) testPushAttachments {
    if (self.isSQLiteDB)
        return;
    [self createDocsIn: db withAttachments: YES];
    Log(@"Pushing...");
    CBLReplication* repl = [db createPushReplication: listenerDBURL];
    [self runReplication: repl expectedChangesCount: 0];
    [self verifyDocsIn: listenerDB withAttachments: YES];
}

- (void) testPullAttachments {
    [self createDocsIn: listenerDB withAttachments: YES];
    Log(@"Pulling...");
    CBLReplication* repl = [db createPullReplication: listenerDBURL];
    [self runReplication: repl expectedChangesCount: 0];
    [self verifyDocsIn: db withAttachments: YES];
}


- (void) createDocsIn: (CBLDatabase*)database withAttachments: (BOOL)withAttachments {
    Log(@"Creating %d documents in %@...", kNDocuments, database.name);
    [database inTransaction:^BOOL{
        for (int i = 1; i <= kNDocuments; i++) {
            @autoreleasepool {
                CBLDocument* doc = database[ $sprintf(@"doc-%d", i) ];
                CBLUnsavedRevision* rev = doc.newRevision;
                rev[@"index"] = @(i);
                rev[@"bar"] = @NO;
                if (withAttachments) {
                    NSUInteger length = (NSUInteger)(kMinAttachmentLength +
                         random()/(double)INT32_MAX*(kMaxAttachmentLength - kMinAttachmentLength));
                    NSMutableData* data = [NSMutableData dataWithLength: length];
                    SecRandomCopyBytes(kSecRandomDefault, length, data.mutableBytes);
                    [rev setAttachmentNamed: @"README" withContentType: @"application/octet-stream"
                                    content: data];
                }
                NSError* error;
                Assert([rev save: &error] != nil, @"Error saving rev: %@", error);
                AssertNil(error);
            }
        }
        return YES;
    }];
}

- (void) verifyDocsIn: (CBLDatabase*)database withAttachments: (BOOL)withAttachments {
    for (int i = 1; i <= kNDocuments; i++) {
        CBLDocument* doc = database[ $sprintf(@"doc-%d", i) ];
        AssertEqual(doc.properties[@"index"], @(i));
        AssertEqual(doc.properties[@"bar"], $false);
        if (withAttachments)
            Assert([doc.currentRevision attachmentNamed: @"README"] != nil);
    }
    AssertEq(database.documentCount, (unsigned)kNDocuments);
}


- (void) runReplication: (CBLReplication*)repl
         expectedChangesCount: (NSUInteger)expectedChangesCount
{
#if USE_AUTH
    repl.authenticator = [CBLAuthenticator basicAuthenticatorWithName: @"bob"
                                                             password: @"slack"];
#endif
    [repl start];
    __block bool started = false;
    [self expectationForNotification: kCBLReplicationChangeNotification object: repl
                             handler: ^BOOL(NSNotification *n) {
                                 Log(@"Repl running=%d, status=%d", repl.running, repl.status);
                                 if (repl.running)
                                     started = true;
                                 if (repl.lastError)
                                     return true;
                                 return started && (repl.status == kCBLReplicationStopped ||
                                                    repl.status == kCBLReplicationIdle);
                             }];
    [self waitForExpectationsWithTimeout: 30.0 handler: nil];
    AssertNil(repl.lastError);
    if (expectedChangesCount > 0) {
        AssertEq(repl.completedChangesCount, expectedChangesCount);
    }
}


@end




@interface P2P_BLIP_Tests : P2P_HTTP_Tests
@end

@implementation P2P_BLIP_Tests

- (Class) listenerClass {
    return [CBLSyncListener class];
}

- (NSString*) replicatorClassName {
    return @"CBLBlipReplicator";
}

- (void) testPush               {[super testPush];}
- (void) testPull               {[super testPull];}
- (void) testPushAttachments    {[super testPushAttachments];}
- (void) testPullAttachments    {[super testPullAttachments];}

- (void) runReplication: (CBLReplication*)repl
         expectedChangesCount: (NSUInteger)expectedChangesCount
{
    [super runReplication: repl expectedChangesCount: expectedChangesCount];
    // Wait for the listener-side connection to finish:
    [self keyValueObservingExpectationForObject: listener keyPath: @"connectionCount" expectedValue: @0];
    [self waitForExpectationsWithTimeout: 5.0 handler: nil];
}

@end

